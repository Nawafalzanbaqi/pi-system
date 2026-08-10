// seo-toolkit — JSON-LD <script> emitter (pi-system module). Server component.
//
// Renders the site-wide Organization + WebSite structured data as
// <script type="application/ld+json">. A NEW component (no collision with
// web-analytics' Analytics.jsx). It is OPT-IN per page rather than auto-injected,
// precisely so it does NOT have to ship a root template.jsx (which would collide
// with web-analytics' template.jsx). Drop it into your home page (or a layout you
// own) once:
//
//   import StructuredData from '@/components/StructuredData';   // or relative
//   export default function Home() {
//     return (<>
//       <StructuredData />
//       {/* ...page... */}
//     </>);
//   }
//
// Server component => the values are read on the server and written into the HTML;
// nothing reaches client JS.
import { seoConfig } from '../lib/seo/config.js';
import { allLd } from '../lib/seo/structured-data.js';

export default function StructuredData() {
  const blocks = allLd(seoConfig());
  return (
    <>
      {blocks.map((obj, i) => (
        <script
          key={i}
          type="application/ld+json"
          // JSON.stringify output is safe to inline as ld+json.
          dangerouslySetInnerHTML={{ __html: JSON.stringify(obj) }}
        />
      ))}
    </>
  );
}
