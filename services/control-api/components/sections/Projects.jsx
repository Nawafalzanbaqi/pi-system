'use client';
// Projects.jsx — list (live /api/projects), per-project start/stop (live
// POST /api/actions/project-{up,down} via ConfirmDialog), and the New-Project
// wizard — now fully WIRED (control-panel part #3). The wizard builds the exact
// generate payload (lib/wizard-payload.js) and, on review → confirm, POSTs it to
// /api/projects, which validates every field again and scaffolds the project
// through the secure generation bridge (operator-only, no shell, no --force; see
// lib/generate-core.js + scripts/bot-exec-generate.sh). On success it shows the
// new project + deploy stepper and refreshes the list. Generation creates the
// FILES only; bringing the site up is the separate Start (project-up) action.
import { useMemo, useState } from 'react';
import { F_AR, F_EN, F_MONO, stateToKind } from '../theme.js';
import { Pill, Dot, Icon, IconButton, btnPrimary, btnGhost } from '../primitives.jsx';
import { SkeletonProjects, EmptyState, ErrorState } from '../states.jsx';
import { motion } from 'framer-motion';
import { usePolledResource, POLL_MS } from '../use-api.js';
import { adaptProjects } from '../../lib/adapt.js';
import { buildCreateConfirm } from '../../lib/wizard-payload.js';
import { PRESETS, DATABASES, MODULES, STAGE_DEFS, PRESET_NAMES_AR, PRESET_NAMES_EN, moduleLabel } from '../catalog.js';

export default function Projects({ t, L, lang, client, confirm, isOperator, onNewProjectRef }) {
  const projects = usePolledResource(() => client.getProjects(), { intervalMs: POLL_MS * 3 });
  const pj = useMemo(() => adaptProjects(projects.data), [projects.data]);
  const [filter, setFilter] = useState('all');
  const [wizardOpen, setWizardOpen] = useState(false);
  const [detail, setDetail] = useState(null);

  if (onNewProjectRef) onNewProjectRef.current = () => setWizardOpen(true);

  const list = pj.projects;
  const filtered = list.filter((p) => (filter === 'all' ? true : p.state === filter));

  const projAction = (action, name, conf) => confirm.ask({
    ...conf,
    onConfirm: async () => {
      const res = await client.runAction(action, { project: name });
      if (!res.ok) throw new Error(res.error || 'action failed');
      setTimeout(() => projects.refresh(), 400);
    },
  });

  const counts = { all: list.length, up: list.filter((p) => p.state === 'up').length, degraded: list.filter((p) => p.state === 'degraded').length };

  const Tabs = (
    <div style={{ display: 'inline-flex', background: t.panel, border: `1px solid ${t.border}`, borderRadius: 7, padding: 2 }}>
      {[{ k: 'all', label: L.filter_all, kind: null }, { k: 'up', label: L.filter_up, kind: 'ok' }, { k: 'degraded', label: L.filter_degraded, kind: 'warn' }].map((o) => (
        <button key={o.k} onClick={() => setFilter(o.k)} style={{ padding: '4px 10px', borderRadius: 5, border: 'none', cursor: 'pointer', background: filter === o.k ? t.panelAlt : 'transparent', color: filter === o.k ? t.ink : t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: filter === o.k ? 600 : 500, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
          {o.kind ? <Dot kind={o.kind} t={t} size={6} /> : null}{o.label}
          <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{counts[o.k]}</span>
        </button>
      ))}
    </div>
  );

  let body;
  if (projects.state === 'loading' && !projects.data) body = <SkeletonProjects t={t} count={6} />;
  else if (projects.state === 'error') body = (
    <ErrorState t={t} lang={lang} title={lang === 'ar' ? 'تعذّر جلب المشاريع' : "Couldn't load projects"} body={lang === 'ar' ? 'تأكّد أنّ المنصّة تعمل ثمّ أعد المحاولة.' : 'Make sure the platform is running, then retry.'} retryLabel={lang === 'ar' ? 'أعد المحاولة' : 'Retry'} onRetry={() => projects.refresh()} detail={projects.error} />
  );
  else if (list.length === 0) body = (
    <EmptyState t={t} lang={lang} icon="box" title={lang === 'ar' ? 'لا توجد مشاريع بعد' : 'No projects yet'} body={lang === 'ar' ? 'أنشئ أول موقع بخطوات واضحة.' : 'Spin up your first site with the guided wizard.'} action={{ label: L.new_project, onClick: () => setWizardOpen(true) }} />
  );
  else if (filtered.length === 0) body = (
    <EmptyState t={t} lang={lang} icon="box" title={lang === 'ar' ? 'لا تطابق مع الفلتر' : 'No projects match this filter'} secondary={{ label: lang === 'ar' ? 'عرض الكل' : 'Show all', onClick: () => setFilter('all') }} />
  );
  else body = (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14 }}>
      {filtered.map((p) => (
        <ProjectCard key={p.name} project={p} t={t} lang={lang} L={L} isOperator={isOperator} onOpen={() => setDetail(p)}
          onStart={() => projAction('project-up', p.name, { title: lang === 'ar' ? `تشغيل ${p.name}؟` : `Start ${p.name}?`, target: `${p.subdomain}.pi.local`, destructive: false, confirmLabel: lang === 'ar' ? 'تشغيل' : 'Start', message: lang === 'ar' ? 'سيُنشر الموقع ويصبح متاحًا.' : 'The site will come up and become reachable.' })}
          onStop={() => projAction('project-down', p.name, { title: lang === 'ar' ? `إيقاف ${p.name}؟` : `Stop ${p.name}?`, target: `${p.subdomain}.pi.local`, impact: ['caddy'], destructive: true, confirmLabel: lang === 'ar' ? 'إيقاف الموقع' : 'Stop the site', message: lang === 'ar' ? 'سيتوقّف الموقع ويصبح غير متاح حتّى إعادة التشغيل.' : 'The site will go down and become unreachable until you start it again.' })} />
      ))}
    </div>
  );

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', position: 'relative' }}>
      <div style={{ padding: '16px 28px 0' }}>{Tabs}</div>
      <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '14px 28px 28px', position: 'relative' }}>
        {detail ? (
          <ProjectDetail project={detail} t={t} L={L} lang={lang} isOperator={isOperator} onBack={() => setDetail(null)}
            onAction={(action) => projAction(action, detail.name, { title: action === 'project-up' ? (lang === 'ar' ? 'تشغيل المشروع؟' : 'Start project?') : (lang === 'ar' ? 'إيقاف المشروع؟' : 'Stop project?'), target: `${detail.subdomain}.pi.local`, destructive: action === 'project-down', confirmLabel: action === 'project-up' ? (lang === 'ar' ? 'تشغيل' : 'Start') : (lang === 'ar' ? 'إيقاف' : 'Stop') })} />
        ) : body}
      </div>
      {wizardOpen ? (
        <NewProjectWizard
          t={t} L={L} lang={lang} client={client} confirm={confirm} isOperator={isOperator}
          onClose={() => setWizardOpen(false)}
          onCreated={(name) => { setTimeout(() => projects.refresh(), 400); }}
        />
      ) : null}
    </div>
  );
}

// ---- Project card ----------------------------------------------------------
function ProjectCard({ project, t, lang, L, onOpen, onStart, onStop, isOperator }) {
  const [hover, setHover] = useState(false);
  const presetName = lang === 'ar' ? PRESET_NAMES_AR[project.preset] : PRESET_NAMES_EN[project.preset];
  return (
    <div onClick={onOpen} onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{ background: t.panel, border: `1px solid ${hover ? t.inkMuted : t.border}`, borderRadius: 12, padding: '16px 16px 12px', display: 'flex', flexDirection: 'column', gap: 12, cursor: 'pointer', transform: hover ? 'translateY(-1px)' : 'translateY(0)', transition: 'border-color 150ms, transform 150ms' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 10 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 3, minWidth: 0, flex: 1 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span style={{ fontFamily: F_MONO, fontSize: 14, fontWeight: 600, color: t.ink, letterSpacing: '-.01em', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{project.name}</span>
            <Dot kind={stateToKind(project.state)} t={t} size={7} />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            {presetName ? <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.inkSoft }}>{presetName}</span> : null}
            <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted }}>{project.subdomain}.pi.local</span>
          </div>
        </div>
      </div>
      {project.modules?.length ? (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
          {project.modules.slice(0, 4).map((m) => <span key={m} style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.inkSoft, background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 5, padding: '2px 7px' }}>{moduleLabel(m, lang)}</span>)}
          {project.modules.length > 4 ? <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted, border: `1px dashed ${t.border}`, borderRadius: 5, padding: '2px 7px' }}>+{project.modules.length - 4}</span> : null}
        </div>
      ) : null}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', paddingTop: 8, borderTop: `1px solid ${t.borderSoft}` }}>
        <div style={{ display: 'flex', gap: 4 }}>
          <SmallBtn t={t} icon="open" onClick={(e) => { e.stopPropagation(); onOpen(); }}>{L.open}</SmallBtn>
          {isOperator ? (
            <SmallBtn t={t} icon={project.state === 'up' ? 'stop' : 'play'} onClick={(e) => { e.stopPropagation(); project.state === 'up' ? onStop() : onStart(); }}>{project.state === 'up' ? L.stop : L.start}</SmallBtn>
          ) : null}
        </div>
        <span style={{ fontFamily: F_MONO, fontSize: 10, color: t.inkMuted }}>{project.deployedAt ? `${L.deployed} · ${project.deployedAt}` : (L.states[project.state] || project.state)}</span>
      </div>
    </div>
  );
}

const SmallBtn = ({ children, t, icon, onClick }) => (
  <button onClick={onClick} style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '4px 8px', borderRadius: 6, background: 'transparent', border: '1px solid transparent', color: t.inkSoft, cursor: 'pointer', fontFamily: F_EN, fontSize: 11 }}
    onMouseEnter={(e) => { e.currentTarget.style.borderColor = t.border; e.currentTarget.style.background = t.panelAlt; e.currentTarget.style.color = t.ink; }}
    onMouseLeave={(e) => { e.currentTarget.style.borderColor = 'transparent'; e.currentTarget.style.background = 'transparent'; e.currentTarget.style.color = t.inkSoft; }}>
    {icon ? <Icon name={icon} size={11} stroke="currentColor" /> : null}{children}
  </button>
);

// ---- Project detail --------------------------------------------------------
function ProjectDetail({ project, t, L, lang, onBack, onAction, isOperator }) {
  const stages = project.stages?.length ? project.stages : STAGE_DEFS.map((s) => ({ name: s.id, status: project.state === 'up' ? 'done' : 'pending', percent: project.state === 'up' ? 100 : 0 }));
  return (
    <>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', paddingBottom: 14 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <button onClick={onBack} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: 0, background: 'transparent', border: 'none', cursor: 'pointer', color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11 }}>
            <Icon name={lang === 'ar' ? 'arrowR' : 'arrowL'} size={11} stroke={t.inkSoft} />{L.detail_back}
          </button>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <h1 style={{ margin: 0, fontFamily: F_MONO, fontSize: 22, fontWeight: 600, color: t.ink, letterSpacing: '-.01em' }}>{project.name}</h1>
            <Pill kind={stateToKind(project.state)} t={t}><span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.states[project.state] || project.state}</span></Pill>
            <span style={{ fontFamily: F_MONO, fontSize: 12, color: t.inkMuted }}>{project.subdomain}.pi.local</span>
          </div>
        </div>
        {isOperator ? (
          <div style={{ display: 'flex', gap: 8 }}>
            {project.state === 'up'
              ? <button style={btnGhost(t, lang)} onClick={() => onAction('project-down')}>{lang === 'ar' ? 'إيقاف' : 'Stop'}</button>
              : <button style={btnPrimary(t, lang)} onClick={() => onAction('project-up')}>{lang === 'ar' ? 'تشغيل' : 'Start'}</button>}
          </div>
        ) : null}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 14 }}>
        <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px 16px' }}>
          <h3 style={{ margin: '0 0 12px', fontSize: 14, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.detail_stages}</h3>
          <DeployStepper stages={stages} t={t} L={L} lang={lang} />
        </section>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px 16px', display: 'flex', flexDirection: 'column', gap: 10 }}>
            <h3 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.detail_overview}</h3>
            <DetailRow t={t} lang={lang} label={lang === 'ar' ? 'القالب' : 'Preset'} value={(lang === 'ar' ? PRESET_NAMES_AR : PRESET_NAMES_EN)[project.preset] || project.preset} />
            <DetailRow t={t} lang={lang} label={lang === 'ar' ? 'النطاق' : 'URL'} mono value={`https://${project.subdomain}.pi.local`} />
            <DetailRow t={t} lang={lang} label={lang === 'ar' ? 'اللغة' : 'Locale'} mono value={project.locale === 'ar' ? 'ar-SA · RTL' : 'en-US · LTR'} />
            {project.deployedAt ? <DetailRow t={t} lang={lang} label={lang === 'ar' ? 'تاريخ النشر' : 'Deployed'} mono value={project.deployedAt} /> : null}
          </section>
          {project.modules?.length ? (
            <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px 16px' }}>
              <h3 style={{ margin: '0 0 10px', fontSize: 14, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.detail_modules}</h3>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5 }}>
                {project.modules.map((m) => <span key={m} style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.inkSoft, background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 5, padding: '3px 8px' }}>{moduleLabel(m, lang)}</span>)}
              </div>
            </section>
          ) : null}
        </div>
      </div>
    </>
  );
}

const DetailRow = ({ label, value, mono, t, lang }) => (
  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
    <span style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{label}</span>
    <span style={{ fontSize: 12, color: t.ink, fontFamily: mono ? F_MONO : (lang === 'ar' ? F_AR : F_EN), fontWeight: 500 }}>{value}</span>
  </div>
);

const stageKind = (status) => (status === 'done' ? 'ok' : status === 'running' ? 'warn' : status === 'failed' ? 'bad' : 'muted');
function DeployStepper({ stages, t, L, lang }) {
  return (
    <ol style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column' }}>
      {stages.map((s, i) => {
        const def = STAGE_DEFS.find((d) => d.id === s.name) || { ar: s.name, en: s.name, ar_sub: '', en_sub: '' };
        const isLast = i === stages.length - 1;
        const kind = stageKind(s.status);
        const color = kind === 'ok' ? t.ok : kind === 'warn' ? t.warn : kind === 'bad' ? t.bad : t.inkMuted;
        return (
          <li key={s.name} style={{ display: 'flex', gap: 12, alignItems: 'stretch' }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', minWidth: 24 }}>
              <span style={{ width: 24, height: 24, borderRadius: '50%', flexShrink: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', background: s.status === 'done' ? t.ok : s.status === 'running' ? t.warnSoft : t.panelAlt, color: s.status === 'done' ? t.bg : color, border: `1.5px solid ${color}` }}>
                {s.status === 'done' ? <Icon name="check" size={12} stroke={t.bg} strokeWidth={2.4} /> : <span style={{ fontFamily: F_MONO, fontSize: 11 }}>{i + 1}</span>}
              </span>
              {!isLast ? <span style={{ flex: 1, width: 1.5, marginTop: 2, background: s.status === 'done' ? t.ok : t.border, minHeight: 24 }} /> : null}
            </div>
            <div style={{ flex: 1, paddingBottom: isLast ? 0 : 14 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                  <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: 600, color: t.ink }}>{lang === 'ar' ? def.ar : def.en}</span>
                  <span style={{ fontFamily: F_MONO, fontSize: 11, color: t.inkMuted }}>{lang === 'ar' ? def.ar_sub : def.en_sub}</span>
                </div>
                <Pill kind={kind} t={t}><span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L[s.status] || s.status}</span></Pill>
              </div>
            </div>
          </li>
        );
      })}
    </ol>
  );
}

// ---- New-project wizard ----------------------------------------------------
const STEP_KEYS = ['preset', 'db', 'modules', 'subdomain', 'locale', 'review'];

function NewProjectWizard({ t, L, lang, client, confirm, isOperator, onClose, onCreated }) {
  const [step, setStep] = useState(0);
  const [created, setCreated] = useState(null);   // success result -> deploy view
  const [error, setError] = useState(null);       // clear, specific submit error
  const [state, setState] = useState({ preset: 'ecommerce', db: 'postgres', modules: PRESETS.find((p) => p.id === 'ecommerce').defaults, subdomain: '', locale: 'ar' });

  const setPreset = (id) => setState((s) => ({ ...s, preset: id, modules: PRESETS.find((p) => p.id === id).defaults }));
  const toggleModule = (id) => setState((s) => ({ ...s, modules: s.modules.includes(id) ? s.modules.filter((x) => x !== id) : [...s.modules, id] }));
  const canAdvance = () => (step === 3 ? state.subdomain.trim().length >= 2 : true);
  // PURE: validate + build the request body and the confirm-dialog copy.
  const cc = useMemo(() => buildCreateConfirm(state, lang), [state, lang]);

  // Review step → confirm dialog (names exactly what will be created) → POST →
  // pending → success (deploy view) | clear error. The dialog drives pending/Done;
  // an error closes it and surfaces a specific message back on the review step.
  const submit = () => {
    if (!cc.valid || !isOperator) return;
    setError(null);
    confirm.ask({
      title: cc.title,
      target: cc.target,
      message: cc.message,
      destructive: false,
      confirmLabel: L.create,
      onConfirm: async () => {
        const res = await client.createProject(cc.payload);
        if (!res.ok) {
          const msg = res.status === 409 ? L.create_err_conflict
            : (res.forbidden || res.status === 403) ? L.create_err_permission
              : res.status === 400 ? L.create_err_validation
                : (res.error || L.create_err_generic);
          throw new Error(msg);
        }
        setCreated(res.data || cc.payload);
        onCreated?.(cc.payload.name);
      },
      onError: (e) => { setError(e?.message || L.create_err_generic); confirm.close(); },
    });
  };

  const lastStep = step === STEP_KEYS.length - 1;

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 50, background: 'rgba(0,0,0,0.42)', backdropFilter: 'blur(2px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 24 }} onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <motion.div initial={{ y: 8, scale: 0.985, opacity: 0 }} animate={{ y: 0, scale: 1, opacity: 1 }} transition={{ duration: 0.22, ease: [0.2, 0.7, 0.3, 1] }}
        style={{ width: 'min(960px, 100%)', height: 'min(640px, 100%)', background: t.panel, borderRadius: 14, overflow: 'hidden', border: `1px solid ${t.border}`, boxShadow: '0 24px 80px rgba(0,0,0,0.30), 0 2px 6px rgba(0,0,0,0.15)' }}>
        <div style={{ display: 'flex', height: '100%' }}>
          <aside style={{ width: 240, flexShrink: 0, background: t.panelAlt, borderInlineEnd: `1px solid ${t.border}`, padding: '18px 18px 16px', display: 'flex', flexDirection: 'column', gap: 14 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <h2 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.wizard_title}</h2>
              <IconButton t={t} onClick={onClose}><Icon name="x" size={12} stroke={t.inkSoft} /></IconButton>
            </div>
            <ol style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
              {STEP_KEYS.map((k, i) => {
                const active = i === step && !created; const done = i < step || created;
                return (
                  <li key={k} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 8px', borderRadius: 7, background: active ? t.panel : 'transparent', border: `1px solid ${active ? t.border : 'transparent'}` }}>
                    <span style={{ width: 20, height: 20, borderRadius: '50%', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', background: done ? t.ink : active ? t.panel : t.panelAlt, color: done ? t.bg : t.inkSoft, border: `1px solid ${done ? t.ink : t.border}`, fontFamily: F_MONO, fontSize: 10, fontWeight: 600 }}>{done ? <Icon name="check" size={11} stroke={t.bg} strokeWidth={2} /> : i + 1}</span>
                    <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 12, fontWeight: active ? 600 : 500, color: active ? t.ink : t.inkSoft }}>{L[`step_${k}`]}</span>
                  </li>
                );
              })}
            </ol>
            <div style={{ flex: 1 }} />
            <p style={{ margin: 0, fontSize: 11, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN, lineHeight: 1.4 }}>{lang === 'ar' ? 'يمكنك تعديل القالب والوحدات لاحقًا.' : 'You can change preset & modules later.'}</p>
          </aside>

          <section style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, background: t.panel }}>
            <div style={{ flex: 1, padding: '24px 28px', overflow: 'auto' }}>
              {created ? <CreatedView t={t} L={L} lang={lang} created={created} />
                : (
                  <>
                    {error && lastStep ? (
                      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10, padding: '12px 14px', marginBottom: 14, background: t.badSoft, border: `1px solid ${t.bad}33`, borderRadius: 10 }}>
                        <span style={{ width: 8, height: 8, borderRadius: '50%', background: t.bad, marginTop: 5, flexShrink: 0 }} />
                        <span style={{ fontSize: 12.5, lineHeight: 1.5, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{error}</span>
                      </div>
                    ) : null}
                    <WizardStep step={step} state={state} setState={setState} setPreset={setPreset} toggleModule={toggleModule} t={t} L={L} lang={lang} />
                  </>
                )}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 22px', borderTop: `1px solid ${t.border}`, background: t.panelAlt }}>
              <button onClick={onClose} style={btnGhost(t, lang)}>{created ? L.close : L.cancel}</button>
              {created ? (
                <button onClick={onClose} style={{ ...btnPrimary(t, lang), display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                  <Icon name="open" size={12} stroke={t.bg} />{L.create_open_project}
                </button>
              ) : (
                <div style={{ display: 'flex', gap: 8 }}>
                  <button onClick={() => setStep((s) => Math.max(0, s - 1))} disabled={step === 0} style={{ ...btnGhost(t, lang), opacity: step === 0 ? 0.4 : 1, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                    <Icon name={lang === 'ar' ? 'arrowR' : 'arrowL'} size={12} stroke={t.inkSoft} />{L.back}
                  </button>
                  {!lastStep ? (
                    <button onClick={() => setStep((s) => Math.min(STEP_KEYS.length - 1, s + 1))} disabled={!canAdvance()} style={{ ...btnPrimary(t, lang), opacity: canAdvance() ? 1 : 0.5, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      {L.next}<Icon name={lang === 'ar' ? 'arrowL' : 'arrowR'} size={12} stroke={t.bg} />
                    </button>
                  ) : (
                    <button onClick={submit} disabled={!cc.valid || !isOperator} style={{ ...btnPrimary(t, lang), opacity: (cc.valid && isOperator) ? 1 : 0.5, display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                      <Icon name="check" size={12} stroke={t.bg} strokeWidth={2} />{L.create}
                    </button>
                  )}
                </div>
              )}
            </div>
          </section>
        </div>
      </motion.div>
    </div>
  );
}

// Success view — the project FILES are generated; deploy is a separate Start
// action. Shows the deploy stepper with only "generate" done to make that explicit.
function CreatedView({ t, L, lang, created }) {
  const name = created.created || created.name;
  const subdomain = created.subdomain || name;
  const modules = Array.isArray(created.modules) ? created.modules : [];
  const stages = STAGE_DEFS.map((s) => ({ name: s.id, status: s.id === 'generate' ? 'done' : 'pending', percent: s.id === 'generate' ? 100 : 0 }));
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, padding: '14px 16px', background: t.okSoft, border: `1px solid ${t.ok}33`, borderRadius: 10 }}>
        <span style={{ width: 30, height: 30, borderRadius: '50%', background: t.ok, flexShrink: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="check" size={15} stroke="#fff" strokeWidth={2.4} /></span>
        <div>
          <h3 style={{ margin: 0, fontSize: 15, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.create_done_title}</h3>
          <p style={{ margin: '4px 0 0', fontSize: 12.5, lineHeight: 1.5, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.create_done_body}</p>
        </div>
      </div>
      <div style={{ background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 10, padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ fontFamily: F_MONO, fontSize: 15, fontWeight: 600, color: t.ink }}>{name}</span>
          <span style={{ fontFamily: F_MONO, fontSize: 12, color: t.inkMuted }} dir="ltr">https://{subdomain}.pi.local</span>
        </div>
        {modules.length ? (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5 }}>
            {modules.map((m) => <span key={m} style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.inkSoft, background: t.panel, border: `1px solid ${t.border}`, borderRadius: 5, padding: '2px 7px' }}>{moduleLabel(m, lang)}</span>)}
          </div>
        ) : null}
      </div>
      <section style={{ background: t.panel, border: `1px solid ${t.border}`, borderRadius: 12, padding: '14px 16px 16px' }}>
        <h3 style={{ margin: '0 0 12px', fontSize: 14, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.detail_stages}</h3>
        <DeployStepper stages={stages} t={t} L={L} lang={lang} />
      </section>
      <p style={{ margin: 0, fontSize: 12, lineHeight: 1.5, color: t.inkMuted, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{L.create_deploy_note}</p>
    </div>
  );
}

// ---- Wizard steps ----------------------------------------------------------
function WizardStep({ step, state, setState, setPreset, toggleModule, t, L, lang }) {
  const key = STEP_KEYS[step];
  if (key === 'preset') return (
    <StepWrap t={t} lang={lang} title={lang === 'ar' ? 'اختر قالب القطاع' : 'Choose a sector preset'} sub={lang === 'ar' ? 'سيُحدد الوحدات الافتراضية المفعّلة.' : 'Determines which modules are pre-selected.'}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10 }}>
        {PRESETS.map((p) => <RadioCard key={p.id} t={t} lang={lang} selected={state.preset === p.id} onClick={() => setPreset(p.id)} icon={p.icon} title={lang === 'ar' ? p.ar : p.en} subtitle={lang === 'ar' ? p.ar_sub : p.en_sub} />)}
      </div>
    </StepWrap>
  );
  if (key === 'db') return (
    <StepWrap t={t} lang={lang} title={lang === 'ar' ? 'اختر قاعدة البيانات' : 'Choose a database'} sub={lang === 'ar' ? 'يمكنك تركها فارغة لمواقع ثابتة.' : 'Leave it empty for static-only sites.'}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10 }}>
        {DATABASES.map((d) => <RadioCard key={d.id} t={t} lang={lang} selected={state.db === d.id} onClick={() => setState((s) => ({ ...s, db: d.id }))} icon="db" title={lang === 'ar' ? d.ar : d.en} subtitle={lang === 'ar' ? d.ar_sub : d.en_sub} badge={d.recommended ? L.recommended : null} />)}
      </div>
    </StepWrap>
  );
  if (key === 'modules') {
    const presetDefaults = PRESETS.find((p) => p.id === state.preset).defaults;
    return (
      <StepWrap t={t} lang={lang} title={lang === 'ar' ? 'الوحدات' : 'Modules'} sub={lang === 'ar' ? 'بدّل ما تشاء.' : 'Toggle as needed.'}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {MODULES.map((m) => <ModuleRow key={m.id} t={t} lang={lang} on={state.modules.includes(m.id)} onToggle={() => toggleModule(m.id)} title={lang === 'ar' ? m.ar : m.en} subtitle={lang === 'ar' ? m.ar_sub : m.en_sub} badge={presetDefaults.includes(m.id) ? L.preselected : null} />)}
        </div>
      </StepWrap>
    );
  }
  if (key === 'subdomain') return (
    <StepWrap t={t} lang={lang} title={lang === 'ar' ? 'النطاق الفرعي' : 'Subdomain'} sub={lang === 'ar' ? 'أحرف لاتينية صغيرة وشَرطة فقط.' : 'Lowercase letters and dashes only.'}>
      <div style={{ maxWidth: 460 }}>
        <div style={{ display: 'flex', alignItems: 'stretch', background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 8, overflow: 'hidden', boxShadow: state.subdomain ? `0 0 0 3px ${t.accentSoft}` : 'none', transition: 'box-shadow 150ms' }}>
          <input type="text" value={state.subdomain} onChange={(e) => setState((s) => ({ ...s, subdomain: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '') }))} placeholder={lang === 'ar' ? 'مثل: noor' : 'e.g. noor'} dir="ltr" style={{ flex: 1, padding: '10px 12px', border: 'none', outline: 'none', background: 'transparent', color: t.ink, fontFamily: F_MONO, fontSize: 14, textAlign: lang === 'ar' ? 'right' : 'left' }} />
          <span style={{ display: 'flex', alignItems: 'center', padding: '0 12px', background: t.panel, color: t.inkSoft, borderInlineStart: `1px solid ${t.border}`, fontFamily: F_MONO, fontSize: 14 }}>.pi.local</span>
        </div>
        <div style={{ marginTop: 8, fontSize: 11, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN, display: 'flex', alignItems: 'center', gap: 6 }}>
          <Icon name="globe" size={11} stroke={t.inkSoft} />{L.subdomain_hint}
          <code style={{ fontFamily: F_MONO, color: state.subdomain ? t.ink : t.inkMuted }}>https://{state.subdomain || '___'}.pi.local</code>
        </div>
      </div>
    </StepWrap>
  );
  if (key === 'locale') return (
    <StepWrap t={t} lang={lang} title={lang === 'ar' ? 'اللغة الافتراضية' : 'Default locale'} sub={lang === 'ar' ? 'يحدد اتجاه الموقع.' : 'Sets the default direction.'}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, maxWidth: 520 }}>
        <RadioCard t={t} lang={lang} selected={state.locale === 'ar'} onClick={() => setState((s) => ({ ...s, locale: 'ar' }))} icon="globe" title={L.locale_ar} subtitle="dir=rtl · ar-SA" />
        <RadioCard t={t} lang={lang} selected={state.locale === 'en'} onClick={() => setState((s) => ({ ...s, locale: 'en' }))} icon="globe" title={L.locale_en} subtitle="dir=ltr · en-US" />
      </div>
    </StepWrap>
  );
  // review
  const preset = PRESETS.find((p) => p.id === state.preset); const db = DATABASES.find((d) => d.id === state.db);
  const rows = [
    { k: L.step_preset, v: lang === 'ar' ? preset.ar : preset.en },
    { k: L.step_db, v: lang === 'ar' ? db.ar : db.en },
    { k: L.step_modules, v: `${state.modules.length} ${lang === 'ar' ? 'وحدة' : 'modules'}` },
    { k: L.step_subdomain, v: state.subdomain ? `${state.subdomain}.pi.local` : '—', mono: true },
    { k: L.step_locale, v: state.locale === 'ar' ? L.locale_ar : L.locale_en },
  ];
  return (
    <StepWrap t={t} lang={lang} title={L.review_title} sub={L.review_sub}>
      <div style={{ background: t.panelAlt, border: `1px solid ${t.border}`, borderRadius: 10, overflow: 'hidden' }}>
        {rows.map((r, i) => (
          <div key={r.k} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '11px 14px', borderBottom: i < rows.length - 1 ? `1px solid ${t.borderSoft}` : 'none' }}>
            <span style={{ fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{r.k}</span>
            <span style={{ fontSize: 13, color: t.ink, fontFamily: r.mono ? F_MONO : (lang === 'ar' ? F_AR : F_EN), fontWeight: 500 }}>{r.v}</span>
          </div>
        ))}
      </div>
      <div style={{ marginTop: 14, display: 'flex', flexWrap: 'wrap', gap: 5 }}>
        {state.modules.map((m) => <span key={m} style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.inkSoft, background: t.panel, border: `1px solid ${t.border}`, borderRadius: 5, padding: '3px 8px' }}>{moduleLabel(m, lang)}</span>)}
      </div>
    </StepWrap>
  );
}

const StepWrap = ({ title, sub, children, t, lang }) => (
  <>
    <div style={{ marginBottom: 16 }}>
      <h3 style={{ margin: 0, fontSize: 18, fontWeight: 600, color: t.ink, fontFamily: lang === 'ar' ? F_AR : F_EN, letterSpacing: '-.005em' }}>{title}</h3>
      {sub ? <p style={{ margin: '4px 0 0', fontSize: 12, color: t.inkSoft, fontFamily: lang === 'ar' ? F_AR : F_EN }}>{sub}</p> : null}
    </div>
    {children}
  </>
);

const RadioCard = ({ selected, onClick, icon, title, subtitle, badge, t, lang }) => (
  <button onClick={onClick} style={{ display: 'flex', alignItems: 'flex-start', gap: 12, padding: '14px 14px', background: selected ? t.panelAlt : t.panel, border: `1px solid ${selected ? t.ink : t.border}`, borderRadius: 10, cursor: 'pointer', textAlign: lang === 'ar' ? 'right' : 'left', boxShadow: selected ? `0 0 0 3px ${t.accentSoft}` : 'none', transition: 'border-color 120ms, box-shadow 150ms, background 120ms' }}>
    <span style={{ width: 34, height: 34, borderRadius: 8, flexShrink: 0, background: t.bg, border: `1px solid ${t.border}`, display: 'flex', alignItems: 'center', justifyContent: 'center', color: t.ink }}><Icon name={icon} size={16} stroke={t.ink} /></span>
    <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 14, fontWeight: 600, color: t.ink }}>{title}</span>
        {badge ? <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.ok, background: t.okSoft, padding: '1px 7px', borderRadius: 999, fontWeight: 600 }}>{badge}</span> : null}
      </div>
      <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.inkSoft }}>{subtitle}</span>
    </div>
    <span style={{ width: 18, height: 18, borderRadius: '50%', flexShrink: 0, border: `1.5px solid ${selected ? t.ink : t.border}`, background: selected ? t.ink : 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{selected ? <Icon name="check" size={12} stroke={t.bg} strokeWidth={2.4} /> : null}</span>
  </button>
);

const ModuleRow = ({ on, onToggle, title, subtitle, badge, t, lang }) => (
  <button onClick={onToggle} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 12px', background: on ? t.panelAlt : t.panel, border: `1px solid ${on ? t.border : t.borderSoft}`, borderRadius: 8, cursor: 'pointer', textAlign: lang === 'ar' ? 'right' : 'left', transition: 'background 120ms, border-color 120ms' }}>
    <span style={{ width: 18, height: 18, borderRadius: 5, border: `1.5px solid ${on ? t.ink : t.border}`, background: on ? t.ink : 'transparent', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>{on ? <Icon name="check" size={11} stroke={t.bg} strokeWidth={2.4} /> : null}</span>
    <div style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
        <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 13, fontWeight: on ? 600 : 500, color: on ? t.ink : t.inkSoft }}>{title}</span>
        <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 11, color: t.inkMuted }}>{subtitle}</span>
      </div>
      {badge ? <span style={{ fontFamily: lang === 'ar' ? F_AR : F_EN, fontSize: 10, color: t.inkSoft, background: t.bg, border: `1px solid ${t.border}`, padding: '2px 7px', borderRadius: 999, flexShrink: 0 }}>{badge}</span> : null}
    </div>
  </button>
);
