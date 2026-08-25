import * as React from 'react';
export interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  prefix?: React.ReactNode;
  suffix?: React.ReactNode;
  size?: 'sm' | 'md' | 'lg';
  invalid?: boolean;
  wrapStyle?: React.CSSProperties;
}
/** Text field with optional prefix/suffix adornments and focus ring. */
export declare function Input(props: InputProps): JSX.Element;
