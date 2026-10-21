// Minimal Telnet client for Synaccess netBooter (NPB) power distribution units. No dependencies.
//
// The device speaks Telnet on port 23 ("Synaccess Telnet V7.1", a "Login:" then a "Password:" prompt, ANSI colours).
// We only ever send read-only commands from here unless a caller passes one explicitly.
import net from 'node:net';

const IAC = 255, DONT = 254, DO = 253, WONT = 252, WILL = 251, SB = 250, SE = 240;

// Strip Telnet option negotiation (refusing every option) and ANSI escape sequences from a chunk.
function cleanChunk(buf, socket) {
  const out = [];
  for (let i = 0; i < buf.length; i++) {
    const b = buf[i];
    if (b !== IAC) { out.push(b); continue; }
    const cmd = buf[++i];
    if (cmd === DO || cmd === DONT) socket.write(Buffer.from([IAC, WONT, buf[++i]]));
    else if (cmd === WILL || cmd === WONT) socket.write(Buffer.from([IAC, DONT, buf[++i]]));
    else if (cmd === SB) { while (i < buf.length && !(buf[i] === IAC && buf[i + 1] === SE)) i++; i++; }
    else if (cmd === IAC) out.push(IAC);
  }
  return Buffer.from(out).toString('latin1').replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');
}

/**
 * Log in and run commands, returning each command's output.
 * @param {{host: string, port?: number, user: string, password: string}} dev
 * @param {string[]} commands  sent one at a time; each result is the text until the device goes quiet
 */
export function netbooterRun(dev, commands = [], { timeout = 10000, idle = 500 } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: dev.host, port: dev.port ?? 23 });
    let text = '', last = Date.now(), done = false;
    const fail = (err) => { if (!done) { done = true; socket.destroy(); reject(err); } };
    const timer = setTimeout(() => fail(new Error(`${dev.host}: timed out`)), timeout);
    socket.on('data', (d) => { text += cleanChunk(d, socket); last = Date.now(); });
    socket.on('error', (e) => fail(new Error(`${dev.host}: ${e.message}`)));
    socket.on('close', () => fail(new Error(`${dev.host}: connection closed`)));

    // Wait until the text matches `re` (or, with no regex, until the device has been quiet for `idle` ms).
    const read = (re) => new Promise((ok, no) => {
      const start = text.length;
      const tick = setInterval(() => {
        const fresh = text.slice(start);
        const quiet = Date.now() - last >= idle;
        if ((re && re.test(fresh)) || (!re && quiet && fresh.length)) { clearInterval(tick); ok(fresh); }
        else if (done) { clearInterval(tick); no(new Error('closed')); }
      }, 50);
    });
    const send = (line) => socket.write(`${line}\r\n`);

    (async () => {
      try {
        await read(/Login:\s*$/i);
        send(dev.user);
        await read(/Password:\s*$/i);
        send(dev.password);
        const reply = await read(); // prompt, or a rejection
        if (/incorrect|invalid|denied|fail|wrong/i.test(reply) || /Login:\s*$/i.test(reply)) throw new Error(`${dev.host}: login rejected`);
        const results = [];
        for (const cmd of commands) { send(cmd); results.push((await read()).replace(/\r/g, '').trim()); }
        done = true; clearTimeout(timer); socket.end(); resolve({ banner: reply.replace(/\r/g, '').trim(), results });
      } catch (e) { clearTimeout(timer); fail(e); }
    })();
  });
}
