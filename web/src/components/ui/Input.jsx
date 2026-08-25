import React from 'react';
export function Input({ prefix, suffix, size = 'md', invalid = false, style = {}, wrapStyle = {}, ...rest }) {
  const [focus, setFocus] = React.useState(false);
  const pad = size === 'lg' ? '14px 16px' : size === 'sm' ? '7px 10px' : '10px 14px';
  const fs = size === 'lg' ? 16 : size === 'sm' ? 13 : 14;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--surface)',
      border: '1px solid ' + (invalid ? 'var(--loss)' : focus ? 'var(--accent)' : 'var(--border-strong)'),
      borderRadius: 'var(--radius-md)', padding: '0 12px',
      boxShadow: focus ? 'var(--ring-focus)' : 'none',
      transition: 'border-color var(--dur-fast), box-shadow var(--dur-fast)', ...wrapStyle }}>
      {prefix && <span style={{ display: 'flex', color: 'var(--text-faint)' }}>{prefix}</span>}
      <input onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
        style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent',
          fontFamily: 'var(--font-body)', fontSize: fs, color: 'var(--text)', padding: pad, minWidth: 0, ...style }} {...rest} />
      {suffix && <span style={{ display: 'flex', color: 'var(--text-faint)' }}>{suffix}</span>}
    </div>
  );
}
