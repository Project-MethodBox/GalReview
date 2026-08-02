import type { Server } from 'node:http';

/**
 * Bind a test HTTP server to an OS-assigned ephemeral port. This avoids fixed
 * ranges that may overlap Windows WinNAT exclusions or another test worker.
 */
export async function listenOnTestPort(
  server: Server,
  host = '127.0.0.1',
): Promise<string> {
  await tryListen(server, 0, host);
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Test server did not bind a TCP port.');
  }
  const originHost = host.includes(':') ? `[${host}]` : host;
  return `http://${originHost}:${address.port}`;
}

async function tryListen(server: Server, port: number, host: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const cleanup = (): void => {
      server.off('error', onError);
      server.off('listening', onListening);
    };
    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const onListening = (): void => {
      cleanup();
      resolve();
    };

    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });
}
