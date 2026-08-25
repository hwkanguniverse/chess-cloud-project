import React from 'react';

const sizes = {
  sm: { padding: '7px 12px', fontSize: 13, height: 32 },
  md: { padding: '10px 16px', fontSize: 14, height: 40 },
  lg: { padding: '13px 22px', fontSize: 15, height: 48 },
};

export function Button({
  children, variant = 'primary', size = 'md', fullWidth = false,
  disabled = false, iconLeft, iconRight, style = {}, ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  const s = sizes[size] || sizes.md;

  const variants = {
    primary: {
      background: hover ? 'var(--n-800)' : 'var(--ink)',
      color: 'var(--text-on-dark)', border: '1px solid var(--ink)',
    },
    secondary: {
      background: hover ? 'var(--surface-2)' : 'var(--surface)',
      color: 'var(--text)', border: '1px solid var(--border-strong)',
    },
    ghost: {
      background: hover ? 'var(--surface-2)' : 'transparent',
      color: 'var(--text)', border: '1px solid transparent',
    },
    accent: {
      background: hover ? 'var(--accent-hover)' : 'var(--accent)',
      color: '#fff', border: '1px solid transparent',
    },
    danger: {
      background: hover ? 'var(--loss-ink)' : 'var(--loss)',
      color: '#fff', border: '1px solid transparent',
    },
  };

  return (
    <button
      disabled={disabled}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => { setHover(false); setPress(false); }}
      onMouseDown={() => setPress(true)}
      onMouseUp={() => setPress(false)}
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        gap: 8, fontFamily: 'var(--font-display)', fontWeight: 600,
        fontSize: s.fontSize, padding: s.padding, minHeight: s.height,
        width: fullWidth ? '100%' : 'auto', borderRadius: 'var(--radius-md)',
        cursor: disabled ? 'not-allowed' : 'pointer', opacity: disabled ? 0.45 : 1,
        transform: press && !disabled ? 'scale(0.98)' : 'scale(1)',
        transition: 'background var(--dur-fast) var(--ease-out), transform var(--dur-fast) var(--ease-out)',
        whiteSpace: 'nowrap', ...variants[variant], ...style,
      }}
      {...rest}
    >
      {iconLeft}{children}{iconRight}
    </button>
  );
}
