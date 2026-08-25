import * as React from 'react';
export interface ResultPillProps { result?: 'win'|'loss'|'draw'; size?: 'sm'|'md'; showDot?: boolean; style?: React.CSSProperties; }
/**
 * The canonical win / loss / draw indicator for a game. Uses the result color language.
 * @startingPoint section="Data" subtitle="Win / loss / draw indicator" viewport="700x120"
 */
export declare function ResultPill(props: ResultPillProps): JSX.Element;
