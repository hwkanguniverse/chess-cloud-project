import * as React from 'react';
export interface BadgeProps { children: React.ReactNode; tone?: 'neutral'|'accent'|'win'|'loss'|'draw'; style?: React.CSSProperties; }
/** Small mono status label. Use win/loss/draw tones for chess results. */
export declare function Badge(props: BadgeProps): JSX.Element;
