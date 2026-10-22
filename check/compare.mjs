// check/compare.mjs: are two declarations.json files the same declarations?
// Prints the first difference (path, left, right) or "identical".
import { readFileSync } from 'node:fs'

function diff(a, b, path = '$') {
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return `${path}: ${a.length} items vs ${b.length}`
    for (let i = 0; i < a.length; i++) {
      const d = diff(a[i], b[i], `${path}[${i}]`)
      if (d) return d
    }
    return null
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])]
    for (const k of keys) {
      const d = diff(a[k], b[k], `${path}.${k}`)
      if (d) return d
    }
    return null
  }
  return a === b ? null : `${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`
}

const [left, right] = process.argv.slice(2)
if (!left || !right) {
  console.error('Usage: node check/compare.mjs left.json right.json')
  process.exit(2)
}
const d = diff(JSON.parse(readFileSync(left, 'utf8')), JSON.parse(readFileSync(right, 'utf8')))
console.log(d ?? 'identical')
process.exit(d ? 1 : 0)
