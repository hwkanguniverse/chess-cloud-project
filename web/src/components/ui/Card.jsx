import React from 'react';
export function Card({ children, padding = 24, hover = false, style = {} }) {
  const [h, setH] = React.useState(false);
  return (
    <div onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--radius-lg)',
        padding, boxShadow: hover && h ? 'var(--shadow-md)' : 'var(--shadow-sm)',
        transform: hover && h ? 'translateY(-2px)' : 'none',
        transition: 'box-shadow var(--dur-normal) var(--ease-out), transform var(--dur-normal) var(--ease-out)', ...style }}>
      {children}
    </div>
  );
}
