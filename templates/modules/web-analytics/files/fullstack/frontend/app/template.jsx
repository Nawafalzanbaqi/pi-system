// web-analytics — root template (pi-system module).
//
// A root `template.jsx` nests INSIDE the root `layout.jsx` and wraps every route,
// so it is the cooperative way to inject something app-wide WITHOUT replacing the
// layout: it does not touch the base's single-locale layout NOR the i18n module's
// per-request <html lang dir> layout — both keep working untouched. (auth-sso's
// per-segment /account layout also nests cleanly underneath.) The only thing this
// adds is the env-gated <Analytics /> tracker, rendered once for the whole app.
//
// Templates re-render on navigation; <Analytics /> uses next/script with a stable
// id, which Next de-duplicates, so the tracker still loads exactly once.
import Analytics from '../components/Analytics';

export default function RootTemplate({ children }) {
  return (
    <>
      {children}
      <Analytics />
    </>
  );
}
