/** @type {import('next').NextConfig} */
const nextConfig = {
  // Emit a self-contained server bundle (.next/standalone) so the Docker runtime
  // image stays small — see the Dockerfile. As of control-panel part #2 this
  // service now ALSO serves the panel UI (App Router pages + components) on the
  // same origin as the API; route handlers under app/api are unchanged.
  output: 'standalone',
  // Quieter, reproducible builds.
  poweredByHeader: false,
};

export default nextConfig;
