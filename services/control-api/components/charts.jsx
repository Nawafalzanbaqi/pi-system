'use client';
// charts.jsx — the chart family, reimplemented on recharts (the prototype used
// hand-rolled inline-SVG stand-ins). Same visual language as the design: thin
// calm lines, soft area fills, dashed warn/fail threshold lines, last-point dot.
// recharts is pure-JS (d3) → ARM64-safe; pinned in package.json.
import { useId } from 'react';
import {
  ResponsiveContainer, AreaChart as RAreaChart, Area, LineChart, Line,
  BarChart as RBarChart, Bar as RBar, Cell, XAxis, YAxis, CartesianGrid, ReferenceLine,
} from 'recharts';
import { F_AR, F_EN, F_MONO, colorForKind } from './theme.js';
import { Pill } from './primitives.jsx';

const toSeries = (arr) => (Array.isArray(arr) ? arr : []).map((v, i) => ({ i, v }));

// Tiny sparkline (KpiCard, per-service memory, SEO minis).
export const Sparkline = ({ data, t, kind = 'ok', height = 22 }) => {
  const color = colorForKind(kind, t);
  return (
    <div style={{ width: '100%', height }}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={toSeries(data)} margin={{ top: 2, right: 2, bottom: 2, left: 2 }}>
          <YAxis hide domain={['dataMin', 'dataMax']} />
          <Line type="monotone" dataKey="v" stroke={color} strokeWidth={1.4} dot={false} isAnimationActive opacity={0.9} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
};

// Full metric area chart with thresholds + a now/avg/max header (Monitoring).
export const AreaChart = ({
  data, t, lang, label, unit = '', height = 160,
  thresholds, niceMin = 0, niceMax, kindOf,
}) => {
  const gid = useId().replace(/[:]/g, '');
  const series = toSeries(data);
  const nums = series.map((d) => d.v);
  const last = nums.length ? nums[nums.length - 1] : 0;
  const avg = nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : 0;
  const dmax = nums.length ? Math.max(...nums) : 0;
  const k = kindOf ? kindOf(last) : 'ok';
  const lineColor = colorForKind(k, t);
  const dec = (u) => (u === '°C' || u === '°م' ? 1 : 0);
  const top = niceMax ?? Math.max(dmax, thresholds?.fail ?? 0) * 1.05;

  return (
    <div style={{ width: '100%' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 8 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
          <span style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span>
          <span style={{ fontSize: 10, color: t.inkMuted, fontFamily: F_MONO }}>
            {lang === 'ar' ? 'الآن' : 'now'} {last.toFixed(dec(unit))}{unit} · {lang === 'ar' ? 'المعدل' : 'avg'} {avg.toFixed(dec(unit))} · {lang === 'ar' ? 'الأعلى' : 'max'} {dmax.toFixed(dec(unit))}
          </span>
        </div>
        <Pill kind={k} t={t}><span style={{ fontFamily: F_MONO, letterSpacing: '.04em' }}>{last.toFixed(dec(unit))}{unit}</span></Pill>
      </div>
      <div style={{ width: '100%', height }}>
        <ResponsiveContainer width="100%" height="100%">
          <RAreaChart data={series} margin={{ top: 6, right: 6, bottom: 0, left: 0 }}>
            <defs>
              <linearGradient id={`area-${gid}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={lineColor} stopOpacity={0.18} />
                <stop offset="100%" stopColor={lineColor} stopOpacity={0.02} />
              </linearGradient>
            </defs>
            <CartesianGrid vertical={false} stroke={t.borderSoft} strokeDasharray="2 4" />
            <XAxis dataKey="i" hide />
            <YAxis hide domain={[niceMin, top]} />
            {thresholds?.warn != null ? (
              <ReferenceLine y={thresholds.warn} stroke={t.warn} strokeDasharray="3 3" strokeOpacity={0.6}
                label={{ value: 'warn', position: 'insideTopRight', fill: t.warn, fontSize: 9, fontFamily: F_MONO }} />
            ) : null}
            {thresholds?.fail != null ? (
              <ReferenceLine y={thresholds.fail} stroke={t.bad} strokeDasharray="3 3" strokeOpacity={0.55}
                label={{ value: 'fail', position: 'insideTopRight', fill: t.bad, fontSize: 9, fontFamily: F_MONO }} />
            ) : null}
            <Area type="monotone" dataKey="v" stroke={lineColor} strokeWidth={1.6} fill={`url(#area-${gid})`}
              dot={false} activeDot={{ r: 3, fill: lineColor }} isAnimationActive />
          </RAreaChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
};

// 7-day visitors bar chart (Growth · Analytics). Last bar emphasised.
export const BarChart7d = ({ data, t, lang, height = 120 }) => {
  const days = lang === 'ar' ? ['س', 'ح', 'ن', 'ث', 'ر', 'خ', 'ج'] : ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  const series = (Array.isArray(data) ? data : []).map((v, i) => ({ i, v, day: days[i] || '' }));
  const lastIdx = series.length - 1;
  return (
    <div style={{ width: '100%', height }}>
      <ResponsiveContainer width="100%" height="100%">
        <RBarChart data={series} margin={{ top: 4, right: 4, bottom: 0, left: 4 }}>
          <XAxis dataKey="day" tickLine={false} axisLine={false}
            tick={{ fill: t.inkMuted, fontSize: 9, fontFamily: F_MONO }} />
          <YAxis hide domain={[0, 'dataMax']} />
          <RBar dataKey="v" radius={[4, 4, 0, 0]} isAnimationActive>
            {series.map((d) => <Cell key={d.i} fill={t.ok} fillOpacity={d.i === lastIdx ? 1 : 0.65} />)}
          </RBar>
        </RBarChart>
      </ResponsiveContainer>
    </div>
  );
};
