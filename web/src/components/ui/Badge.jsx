import React from 'react';
export function Badge({ children, tone = 'neutral', style = {} }) {
  const tones = {
    neutral: { bg: 'var(--surface-2)', fg: 'var(--text-muted)', bd: 'var(--border)' },
    accent: { bg: 'var(--accent-soft)', fg: 'var(--accent-ink)', bd: 'transparent' },
    win: { bg: 'var(--win-soft)', fg: 'var(--win-ink)', bd: 'transparent' },
    loss: { bg: 'var(--loss-soft)', fg: 'var(--loss-ink)', bd: 'transparent' },
    draw: { bg: 'var(--draw-soft)', fg: 'var(--draw-ink)', bd: 'transparent' },
  };
  const t = tones[tone] || tones.neutral;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: 'var(--font-mono)',
      fontSize: 11, fontWeight: 500, letterSpacing: '0.02em', padding: '3px 8px', borderRadius: 'var(--radius-pill)',
      background: t.bg, color: t.fg, border: '1px solid ' + t.bd, ...style }}>{children}</span>
  );
}
