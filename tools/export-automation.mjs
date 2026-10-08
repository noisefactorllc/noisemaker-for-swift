#!/usr/bin/env node
// Evaluate unmodified upstream automation against explicit host input snapshots.
import {readFileSync, mkdirSync, writeFileSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath, pathToFileURL} from 'node:url'
import {fetchVerifiedArchive, sourceIdentity} from './export-reference.mjs'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(join(root, 'parity/reference.json'), 'utf8'))
const archive = process.env.NM_REFERENCE_ROOT ? null : fetchVerifiedArchive(lock)
try {
    const ref = resolve(process.env.NM_REFERENCE_ROOT || archive.root)
    sourceIdentity(ref, lock)
    const {Pipeline} = await import(pathToFileURL(join(ref, 'shaders/src/runtime/pipeline.js')).href)
    const {MidiState, AudioState} = await import(pathToFileURL(join(ref, 'shaders/src/runtime/external-input.js')).href)
    const osc = (oscType = 0, fields = {}) => ({type:'Oscillator', oscType, min:0, max:1, speed:1, offset:0, seed:1, ...fields})
    const audio = (band = 0, fields = {}) => ({type:'Audio', band, min:0, max:1, ...fields})
    const midi = (mode = 4, fields = {}) => ({type:'Midi', mode, channel:1, min:0, max:1, sensitivity:1, ...fields})
    const levels = (fields = {}) => ({low:.13, mid:.29, high:.73, vol:.41, raw:-.25, rawReady:true, ...fields})
    const channel = (fields = {}) => ({key:60, velocity:100, gate:1, time:9750, pitchBend:10240, pressure:94,
        cc:{1:35, 64:127}, cc14:{1:12345}, nrpn:{1000:9876}, polyPressure:{60:84, 71:52}, heldNotes:[], ...fields})
    const state = (fields = {}) => ({channels:{1:channel(), 2:channel({heldNotes:[{key:71,velocity:93,time:9880,order:3}]}),
        15:channel({heldNotes:[{key:82,velocity:125,time:9900,order:4}]})}, lowerZoneMembers:3, upperZoneMembers:2, clockCount:48, ...fields})
    const input = (fields = {}) => ({wallTimeMilliseconds:10000, audio:null, midi:null, ...fields})
    const audioInput = {aggregate:levels(), defaultChannels:{1:levels({low:.3}),2:levels({low:.6})}, devices:[
        {id:'A',name:'Mic',connected:true,channels:{1:levels({low:.7}),2:levels({low:.9})}},
        {id:'B',name:'Dup',connected:true,channels:{1:levels()}},
        {id:'C',name:'Dup',connected:true,channels:{1:levels()}},
        {id:'D',name:'Gone',connected:false,channels:{1:levels()}}]}
    const midiInput = {aggregate:state(),unscoped:state(),ports:[
        {id:'A',name:'Keys',connected:true,state:state({channels:{1:channel({key:36,velocity:90}),
            2:channel({heldNotes:[{key:60,velocity:102,time:9800,order:6}]})}})},
        {id:'B',name:'Dup',connected:true,state:state()}, {id:'C',name:'Dup',connected:true,state:state()},
        {id:'D',name:'Gone',connected:false,state:state()}]}
    function populateState(target, snap) {
        target.clockCount = snap.clockCount
        target.mpeZones = {lower:snap.lowerZoneMembers,upper:snap.upperZoneMembers}
        for (const [n, value] of Object.entries(snap.channels)) {
            const dest = target.getChannel(n)
            for (const key of ['key','velocity','gate','time','pitchBend','pressure']) dest[key] = value[key]
            for (const key of ['cc','cc14','polyPressure']) for (const [k,v] of Object.entries(value[key])) dest[key][k] = v
            dest.nrpn = new Map(Object.entries(value.nrpn).map(([k,v]) => [+k,v]))
            dest.heldNotes = new Map(value.heldNotes.map(v => [v.key,v]))
        }
        return target
    }
    function external(snap) {
        const result = {}
        if (snap.audio) {
            const value = snap.audio, target = new AudioState()
            Object.assign(target, value.aggregate)
            const count = Math.max(0,...Object.keys(value.defaultChannels).map(Number))
            if (count) target.registerDefaultChannels(count)
            for (const [n,s] of Object.entries(value.defaultChannels)) Object.assign(target.getDefaultChannelState(+n),s)
            for (const d of value.devices) {
                const entry = target.registerDevice({...d,channelCount:Math.max(1,...Object.keys(d.channels).map(Number))})
                for (const [n,s] of Object.entries(d.channels)) Object.assign(entry.channels.get(+n),s)
                if (!d.connected) target.disconnectDevice(d.id)
            }
            result.audio = target
        }
        if (snap.midi) {
            const value = snap.midi, target = populateState(new MidiState(), value.aggregate)
            populateState(target._unscopedState, value.unscoped ?? state({channels:{}}))
            for (const p of value.ports) {
                populateState(target.registerPort(p),p.state)
                if (!p.connected) target.disconnectPort(p.id)
            }
            // Port disconnection updates aggregate state. Populate the supplied
            // final snapshot after topology changes, so the oracle sees exact inputs.
            populateState(target, value.aggregate)
            result.midi = target
        }
        return result
    }
    const cases = []
    function add(name, config, time=.137, paramSpec=null, inputs=input()) {
        const originalNow = Date.now
        let expected
        try {
            Date.now = () => inputs.wallTimeMilliseconds
            expected = Pipeline.prototype.resolveUniformValue.call({externalState:external(inputs)},config,time,paramSpec)
        } finally { Date.now = originalNow }
        if (typeof expected !== 'number' || !Number.isFinite(expected)) throw Error(`Nonfinite fixture: ${name}`)
        cases.push({name,config,time,paramSpec,inputs,expected,negativeZero:Object.is(expected,-0)})
    }
    for (let kind=0;kind<7;kind++) for (const time of [-2,-.75,-.01,0,.125,.499,.5,.75,.999,1,1.23,7.125]) {
        add(`osc/${kind}/${time}`,osc(kind),time)
        add(`osc-range/${kind}/${time}`,osc(kind,{min:.2,max:.8,speed:-3,offset:-.3,seed:-57}),time,{min:-4,max:10,type:'int'})
    }
    for (let outer=0;outer<7;outer++) for (let inner=0;inner<7;inner++) {
        add(`frequency/${outer}/${inner}`,osc(outer,{speed:osc(inner,{min:.2,max:.9,speed:3,offset:.17,seed:135})}),.37)
        add(`frequency-negative/${outer}/${inner}`,osc(outer,{speed:osc(inner,{speed:-2,offset:-.3})}),-.7)
    }
    for (const field of ['min','max','offset','seed']) for (let kind=0;kind<7;kind++)
        add(`field/${field}/${kind}`,osc(5,{[field]:osc(kind,{speed:3})}),.271)
    for (let depth=1;depth<=10;depth++) {
        let value=osc(5)
        for(let i=0;i<depth;i++) value=osc(i%7,{speed:value})
        add(`deep-speed/${depth}`,value,.217)
        value=osc(1)
        for(let i=0;i<depth;i++) value=osc(0,{min:value})
        add(`deep-min/${depth}`,value,.367)
    }
    for (let band=0;band<5;band++) for(const selector of [{},{channel:1},{channel:2},{name:'Mic',channel:2},
        {name:'Renamed',id:'A',channel:1},{name:'Dup',channel:1},{name:'Gone',channel:1},{channel:33},
        {name:'Missing',channel:1},{name:'Mic'},{id:'A',channel:1},{channel:null},
        {_ast:{type:'Audio',name:'Mic'}},{_invalid:true}]) {
        add(`audio/${band}/${JSON.stringify(selector)}`,audio(band,{min:.2,max:.8,...selector}),.2,{min:-3,max:11},input({audio:audioInput}))
    }
    for (const raw of [-2,-1,0,.37,1,2]) for(const rawReady of [false,true])
        add(`audio-raw/${raw}/${rawReady}`,audio(4),.2,null,input({audio:{...audioInput,aggregate:levels({raw,rawReady})}}))
    for (let mode=0;mode<=10;mode++) for(const selector of [{},{channel:2},{channel:0},{name:'Keys'},
        {name:'Renamed',id:'A'},{name:'Dup'},{name:'Gone'},{zone:0,channel:undefined},{zone:1,channel:undefined},
        {zone:0,members:1,channel:undefined},{zone:1,members:0,channel:undefined},{zone:0},{members:3},
        {_invalid:true}]) {
        add(`midi/${mode}/${JSON.stringify(selector)}`,midi(mode,{cc:1,nrpn:1000,...selector}),.2,{min:-2,max:3},input({midi:midiInput}))
    }
    for(const cc of [null,0,1,31,32,127,128,-1,1.1,'1']) for(const mode of [5,6])
        add(`midi-cc/${mode}/${cc}`,midi(mode,{cc}),.2,null,input({midi:midiInput}))
    for(const time of [9000,9750,10000,11000]) for(const mode of [3,4])
        add(`midi-decay/${mode}/${time}`,midi(mode),.2,null,input({midi:midiInput,wallTimeMilliseconds:time}))
    for (const value of [audio(0),midi(0),osc(2)]) for (const field of ['speed','min','max'])
        add(`mixed/${value.type}/${field}`,osc(0,{[field]:value}),.61,null,input({audio:audioInput,midi:midiInput}))
    add('int-negative-zero',osc(0,{min:-.2,max:-.2}),0,{type:'int'})
    add('audio-absent',audio(2,{min:.3}),.3)
    add('midi-absent',midi(2,{min:.3}),.3)
    add('ast-type', {...osc(),type:undefined,_ast:{type:'Oscillator'}},.3)
    for (const spec of [{min:-2,max:2},{min:3,max:-2},{min:0},{max:5},{type:'int'}])
        add(`consumer-range/${JSON.stringify(spec)}`,osc(0),.137,spec)
    for (const kind of [0,1,5,6]) add(`zero-speed/${kind}`,osc(kind,{speed:osc(0,{speed:0,offset:.2})}),-.37)
    for (const mode of [0,1,2,3,4,5,8,10])
        add(`midi-sparse/${mode}`,midi(mode,{channel:2}),.2,null,input({midi:{aggregate:state({channels:{1:channel()}}),unscoped:null,ports:[]}}))
    for (const zone of [0,1])
        add(`midi-no-unscoped/${zone}`,midi(0,{zone,channel:undefined}),.2,null,input({midi:{aggregate:state(),unscoped:null,ports:[]}}))
    for (const invalid of ['invalid',1,{},[]]) {
        add(`audio-invalid/${JSON.stringify(invalid)}`,audio(0,{_invalid:invalid}),.2,null,input({audio:audioInput}))
        add(`midi-invalid/${JSON.stringify(invalid)}`,midi(0,{_invalid:invalid}),.2,null,input({midi:midiInput}))
    }
    add('nested-fractional-kind',osc(0,{speed:osc(.5)}),.237)
    const output = resolve(process.argv[2] || join(root,'.build/reference/automation.json'))
    mkdirSync(dirname(output),{recursive:true})
    writeFileSync(output,JSON.stringify({reference:lock,cases},null,2)+'\n')
    console.log(`Automation oracle: ${cases.length} cases`)
} finally { archive?.cleanup() }
