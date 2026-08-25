import * as React from 'react';
export interface StatProps {
  value: React.ReactNode; label?: string; sub?: React.ReactNode;
  tone?: 'default'|'win'|'loss'|'accent'; align?: 'left'|'center'|'right'; style?: React.CSSProperties;
}
/**
 * Big mono KPI figure with an UPPERCASE eyebrow label and optional sub-line.
 * @startingPoint section="Data" subtitle="Headline KPI figure" viewport="700x150"
 */
export declare function Stat(props: StatProps): JSX.Element;
