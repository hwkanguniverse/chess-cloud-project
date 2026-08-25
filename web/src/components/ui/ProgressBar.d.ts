import * as React from 'react';
export interface ProgressSegment { value: number; color: string; label?: string; }
export interface ProgressBarProps {
  value?: number; max?: number; tone?: 'accent'|'win'|'loss'|'ink';
  segments?: ProgressSegment[]; height?: number; style?: React.CSSProperties;
}
/** Single-value bar, or a multi-segment stacked bar (e.g. W/L/D split). */
export declare function ProgressBar(props: ProgressBarProps): JSX.Element;
