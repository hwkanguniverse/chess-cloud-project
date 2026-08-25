import React from 'react';
export function Stat({ value, label, sub, tone = 'default', align = 'left', style = {} }) {
  const colors = { default: 'var(--text)', win: 'var(--win-ink)', loss: 'var(--loss-ink)', accent: 'var(--accent-ink)' };
  return (
    <div style={{ textAlign: align, ...style }}>
      {label && <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, letterSpacing: 'var(--tracking-label)',
        textTransform: 'uppercase', color: 'var(--text-subtle)', marginBottom: 6 }}>{label}</div>}
      <div style={{ fontFamily: 'var(--font-mono)', fontWeight: 700, fontSize: 'var(--fs-stat)', lineHeight: 1,
        letterSpacing: '-0.02em', color: colors[tone] }}>{value}</div>
      {sub && <div style={{ fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-muted)', marginTop: 6 }}>{sub}</div>}
    </div>
  );
}
