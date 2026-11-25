import { useEffect, useId, useMemo, useState, type InputHTMLAttributes, type ReactNode } from 'react'
import { validateImage } from '../../utils/images'

interface Base {
  label: string
  help?: ReactNode
  error?: string | null
  required?: boolean
}

function Wrap({ label, help, error, required, children, id }: Base & { children: ReactNode; id: string }) {
  return (
    <div className="field">
      <label htmlFor={id}>{label}{required ? <span aria-hidden="true"> *</span> : null}</label>
      {children}
      {help && !error && <small className="help" id={`${id}-help`}>{help}</small>}
      {error && <span className="field-error" id={`${id}-err`} role="alert">{error}</span>}
    </div>
  )
}

type InputProps = Base & Omit<InputHTMLAttributes<HTMLInputElement>, 'onChange' | 'value' | 'id'> & { value: string; onChange: (v: string) => void }

export function TextField({ label, help, error, required, value, onChange, ...rest }: InputProps) {
  const id = useId()
  return (
    <Wrap id={id} label={label} help={help} error={error} required={required}>
      <input id={id} value={value} onChange={(e) => onChange(e.target.value)} required={required} aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-err` : help ? `${id}-help` : undefined} {...rest} />
    </Wrap>
  )
}

export function TextAreaField({ label, help, error, required, value, onChange, rows = 3, maxLength, placeholder }: Base & { value: string; onChange: (v: string) => void; rows?: number; maxLength?: number; placeholder?: string }) {
  const id = useId()
  return (
    <Wrap id={id} label={label} help={help} error={error} required={required}>
      <textarea id={id} value={value} onChange={(e) => onChange(e.target.value)} rows={rows} maxLength={maxLength} placeholder={placeholder} required={required} aria-invalid={error ? true : undefined} />
    </Wrap>
  )
}

export function SelectField<T extends string>({ label, help, error, required, value, onChange, options, disabled }: Base & { value: T; onChange: (v: T) => void; options: { value: T; label: string }[]; disabled?: boolean }) {
  const id = useId()
  return (
    <Wrap id={id} label={label} help={help} error={error} required={required}>
      <select id={id} value={value} onChange={(e) => onChange(e.target.value as T)} disabled={disabled} required={required}>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </Wrap>
  )
}

export function CheckField({ label, help, checked, onChange, disabled }: { label: string; help?: ReactNode; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  const id = useId()
  return (
    <div className="field field-check">
      <label htmlFor={id} className="check"><input id={id} type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} /> <span>{label}</span></label>
      {help && <small className="help">{help}</small>}
    </div>
  )
}

/** Picks an image, validates type and size in the browser (the Storage bucket enforces them again) and previews it before anything is uploaded. */
export function ImageField({ label, currentUrl, file, onFile, help, required }: { label: string; currentUrl?: string | null; file: File | null; onFile: (f: File | null) => void; help?: ReactNode; required?: boolean }) {
  const id = useId()
  const [error, setError] = useState<string | null>(null)
  const preview = useMemo(() => (file ? URL.createObjectURL(file) : null), [file])
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview) }, [preview])
  const shown = preview ?? currentUrl ?? null
  return (
    <Wrap id={id} label={label} help={help ?? 'JPEG, PNG or WebP, up to 5 MB.'} error={error} required={required}>
      {shown && <img className="img-preview" src={shown} alt={`${label} preview`} />}
      <input id={id} type="file" accept="image/jpeg,image/png,image/webp" onChange={(e) => {
        const f = e.target.files?.[0] ?? null
        const problem = f ? validateImage(f) : null
        setError(problem)
        onFile(problem ? null : f)
        if (problem) e.target.value = ''
      }} />
    </Wrap>
  )
}
