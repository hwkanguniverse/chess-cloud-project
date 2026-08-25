import React from 'react';
export function ResultPill({ result = 'win', size = 'md', showDot = true, style = {} }) {
  const map = {
    win: { label: 'Win', bg: 'var(--win-soft)', fg: 'var(--win-ink)', dot: 'var(--win)' },
    loss: { label: 'Loss', bg: 'var(--loss-soft)', fg: 'var(--loss-ink)', dot: 'var(--loss)' },
    draw: { label: 'Draw', bg: 'var(--draw-soft)', fg: 'var(--draw-ink)', dot: 'var(--draw)' },
  };
  const r = map[result] || map.win;
  const fs = size === 'sm' ? 11 : 13;
  const pad = size === 'sm' ? '3px 8px' : '5px 11px';
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: 'var(--font-mono)',
      fontWeight: 500, fontSize: fs, padding: pad, borderRadius: 'var(--radius-pill)',
      background: r.bg, color: r.fg, ...style }}>
      {showDot && <span style={{ width: 7, height: 7, borderRadius: '50%', background: r.dot }} />}
      {r.label}
    </span>
  );
}
