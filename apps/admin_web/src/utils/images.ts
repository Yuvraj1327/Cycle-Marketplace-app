/** Browser-side checks for admin image uploads. They mirror the Storage bucket limits (5 MB; JPEG / PNG / WebP); the bucket enforces them again. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024
export const IMAGE_TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }

export function validateImage(file: File): string | null {
  if (!(file.type in IMAGE_TYPES)) return 'Choose a JPEG, PNG or WebP image.'
  if (file.size === 0) return 'That file is empty.'
  if (file.size > MAX_IMAGE_BYTES) return 'The image is larger than 5 MB.'
  return null
}

function uuid(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`
}

/** An unguessable object path inside the `banners` bucket, e.g. `categories/5b1c….png` (never derived from the user's file name). */
export function imagePath(folder: 'banners' | 'categories' | 'service-categories', file: File): string {
  return `${folder}/${uuid()}.${IMAGE_TYPES[file.type] ?? 'jpg'}`
}
