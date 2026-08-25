import * as React from 'react';
export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Visual style. @default 'primary' */
  variant?: 'primary' | 'secondary' | 'ghost' | 'accent' | 'danger';
  /** @default 'md' */
  size?: 'sm' | 'md' | 'lg';
  fullWidth?: boolean;
  iconLeft?: React.ReactNode;
  iconRight?: React.ReactNode;
}
/**
 * Primary action button. Use 'primary' (ink) for the main action on a screen,
 * 'secondary' for adjacent actions, 'ghost' for low-emphasis, 'accent'/'danger' sparingly.
 * @startingPoint section="Core" subtitle="Ink, secondary, ghost, accent" viewport="700x160"
 */
export declare function Button(props: ButtonProps): JSX.Element;
