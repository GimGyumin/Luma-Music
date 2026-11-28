// Invoked by test_replay_history.py --web with a disposable profile and fixture account.
import {spawn} from 'node:child_process'
import {mkdtemp, readFile, rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {once} from 'node:events'

const {base, password} = JSON.parse(process.env.LUMA_REPLAY_FIXTURE)
const profile = await mkdtemp(join(tmpdir(), 'luma-replay-browser-'))
const binary = process.env.CHROME_BINARY || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const browser = spawn(binary, ['--headless', '--no-first-run', '--disable-default-apps', '--disable-sync',
    '--disable-background-networking', '--mute-audio', '--autoplay-policy=no-user-gesture-required',
    '--remote-debugging-port=0', '--user-data-dir=' + profile, base], {stdio: 'ignore'})
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
let socket
try {
    let port
    for (let i = 0; i < 90 && !port; i++) {
        try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0] }
        catch { await sleep(500) }
    }
    const pages = await (await fetch('http://127.0.0.1:' + port + '/json/list')).json()
    socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl)
    await once(socket, 'open')
    let id = 0
    const pending = new Map()
    socket.onmessage = event => {
        const message = JSON.parse(event.data)
        pending.get(message.id)?.(message)
        pending.delete(message.id)
    }
    const command = (method, params) => new Promise(resolve => {
        pending.set(++id, resolve)
        socket.send(JSON.stringify({id, method, params}))
    })
    const evaluate = async expression => (await command('Runtime.evaluate', {expression, returnByValue: true})).result?.result?.value
    const waitFor = async selector => {
        for (let i = 0; i < 60; i++) {
            if (await evaluate('!!document.querySelector(' + JSON.stringify(selector) + ')')) return
            await sleep(250)
        }
        throw Error('Control missing: ' + selector)
    }
    const click = async selector => {
        await waitFor(selector)
        const point = await evaluate('(()=>{const r=document.querySelector(' + JSON.stringify(selector)
            + ').getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}})()')
        for (const type of ['mousePressed', 'mouseReleased']) {
            await command('Input.dispatchMouseEvent', {type, ...point, button:'left', clickCount:1})
        }
    }
    for (const [type, value] of [['text', 'listener'], ['password', password]]) {
        await click('input[type=' + type + ']')
        await command('Input.insertText', {text:value})
    }
    await click('button[type=submit]')
    await waitFor('a[href*="/song"]')
    await evaluate('location.hash="#/song"')
    await click('tbody tr input[type=checkbox]')
    await click('button[aria-label="Play Now"]')

    const login = await (await fetch(base + '/auth/login', {method:'POST', headers:{'Content-Type':'application/json'},
        body:JSON.stringify({username:'listener', password})})).json()
    let added = false
    for (let i = 0; i < 25 && !added; i++) {
        await sleep(4000)
        const rows = await (await fetch(base + '/api/scrobble', {headers:{'x-nd-authorization':'Bearer '+login.token}})).json()
        added = rows.length === 4
    }
    if (!added) throw Error('No confirmed web listen')
    console.log('Web player added a confirmed listen')
} finally {
    socket?.close()
    const closed = once(browser, 'exit')
    browser.kill()
    await closed
    await rm(profile, {recursive:true, force:true, maxRetries:3})
}
