// i18n-bilingual — the root path is locale-prefixed.
//
// The locale middleware already redirects "/" to "/<locale>". This page is a
// defensive fallback for any request that reaches "/" directly (e.g. if the
// middleware matcher is ever narrowed): it redirects to the default locale.
import { redirect } from 'next/navigation';
import { defaultLocale } from '../i18n/config';

export default function RootIndex() {
  redirect(`/${defaultLocale}`);
}
