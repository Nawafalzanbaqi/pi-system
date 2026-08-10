/** @type {import('next').NextConfig} */
const nextConfig = {
  // Emit a self-contained server bundle (.next/standalone) so the Docker
  // runtime image stays small — see the Dockerfile.
  output: 'standalone',
};

export default nextConfig;
