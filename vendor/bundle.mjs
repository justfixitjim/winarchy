// Bundles entry.mjs (React, React DOM, htm, Zebar) into config/zebar/vendor/ui.mjs. Run by build.ps1.
import { build } from 'esbuild';

await build({
  entryPoints: [new URL('./entry.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')],
  outfile: new URL('../config/zebar/vendor/ui.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'),
  bundle: true,
  format: 'esm',
  minify: true,
  target: 'es2022',
  define: { 'process.env.NODE_ENV': '"production"' },  // React's production build
  legalComments: 'eof',                                 // licences collected at the end of the file
});
