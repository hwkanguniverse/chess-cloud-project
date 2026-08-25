import React from 'react';
export function ProgressBar({ segments, value, max = 100, tone = 'accent', height = 10, style = {} }) {
  const toneColor = { accent: 'var(--accent)', win: 'var(--win)', loss: 'var(--loss)', ink: 'var(--ink)' };
  const track = { display: 'flex', width: '100%', height, borderRadius: 999, overflow: 'hidden',
    background: 'var(--surface-sunken)', ...style };
  if (segments && segments.length) {
    const total = segments.reduce((a, s) => a + s.value, 0) || 1;
    return (
      <div style={track}>
        {segments.map((s, i) => (
          <div key={i} title={s.label} style={{ width: (s.value / total * 100) + '%', background: s.color }} />
        ))}
      </div>
    );
  }
  return (
    <div style={track}>
      <div style={{ width: Math.min(100, (value / max) * 100) + '%', background: toneColor[tone] || tone,
        transition: 'width var(--dur-slow) var(--ease-out)' }} />
    </div>
  );
}
