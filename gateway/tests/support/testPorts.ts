import type { Server } from 'node:http';

const FIRST_TEST_PORT = 5260;
const LAST_TEST_PORT = 5299;
const TEST_PORT_COUNT = LAST_TEST_PORT - FIRST_TEST_PORT + 1;

let nextCandidate = FIRST_TEST_PORT + (process.pid % TEST_PORT_COUNT);

/**
 * Bind a test HTTP server inside the repository's reserved test-port range.
 * Parallel Vitest workers may choose the same initial candidate, so occupied
 * ports are skipped until the full range has been tried.
 */
export async function listenOnTestPort(
  server: Server,
  host = '127.0.0.1',
): Promise<string> {
  for (let attempt = 0; attempt < TEST_PORT_COUNT; attempt += 1) {
    const port = nextCandidate;
    nextCandidate = port === LAST_TEST_PORT ? FIRST_TEST_PORT : port + 1;

    try {
      await tryListen(server, port, host);
      return `http://${host}:${port}`;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EADDRINUSE') {
        throw error;
      }
    }
  }

  throw new Error(
    `No available test port in ${FIRST_TEST_PORT}-${LAST_TEST_PORT}.`,
  );
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
