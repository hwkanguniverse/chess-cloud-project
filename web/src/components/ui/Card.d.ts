import * as React from 'react';
export interface CardProps { children: React.ReactNode; padding?: number | string; hover?: boolean; style?: React.CSSProperties; }
/** White surface container. Set hover for a lift-on-hover interaction. */
export declare function Card(props: CardProps): JSX.Element;
