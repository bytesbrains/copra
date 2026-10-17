// In the browser container, 127.0.0.1 is the container itself, so the page's origin and its RPC (anvil's
// host port, as network.js and the CSP name it) are plain TCP forwards to the compose services. Bytes
// pass through untouched: the browser sees wrangler's responses and headers exactly as served.
const net = require('node:net');
const { WEB_PORT, RPC_PORT, WEB_UPSTREAM, CHAIN_UPSTREAM } = require('./env.cjs');

function forward(port, upstream) {
  const [host, upstreamPort] = upstream.split(':');
  const server = net.createServer((client) => {
    const remote = net.connect(Number(upstreamPort), host);
    client.pipe(remote).pipe(client);
    const close = () => { client.destroy(); remote.destroy(); };
    client.on('error', close);
    remote.on('error', close);
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

module.exports = async () => {
  const servers = [];
  if (WEB_UPSTREAM) servers.push(await forward(WEB_PORT, WEB_UPSTREAM));
  if (CHAIN_UPSTREAM) servers.push(await forward(RPC_PORT, CHAIN_UPSTREAM));
  return async () => { for (const s of servers) s.close(); };
};
