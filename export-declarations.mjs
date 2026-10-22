#!/usr/bin/env node
/**
 * export-declarations.mjs
 *
 * Reads a Power BI semantic model saved as a project (<Name>.SemanticModel,
 * TMDL format) and writes declarations.json: the NAMES of its tables, columns
 * and measures, their data types, sort columns and format strings, and which
 * tables are related. Nothing else.
 *
 * What is never read or written: partitions and M queries, DAX expressions
 * (only the first line of a measure is looked at, to tell whether it returns
 * text), annotations, data. Open declarations.json before you send it: it is
 * plain text and you can read every line.
 *
 * Usage:  node export-declarations.mjs <path to .SemanticModel or project folder> [-o declarations.json]
 * Needs Node 18 or later. No dependencies.
 */
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename, join, resolve } from 'node:path'

const AUTO_TABLE = /^(LocalDateTable_|DateTableTemplate_)/
const DATE_WORDS = new Set(['date', 'calendar', 'calendrier', 'calendario', 'fecha', 'datum'])

function isDateTableName(name) {
  return name.split(/[^A-Za-z]+|(?=[A-Z][a-z])/).some((w) => DATE_WORDS.has(w.toLowerCase().replace(/s$/, '')))
}

function leading(line) {
  let tabs = 0
  let spaces = 0
  for (const ch of line) {
    if (ch === '\t') tabs++
    else if (ch === ' ') spaces++
    else break
  }
  return { tabs, spaces }
}

/** Desktop indents with tabs; other tools with 2 or 4 spaces. The smallest space-only indent is the unit. */
function spaceUnitOf(lines) {
  let unit = 0
  for (const line of lines) {
    if (!line.trim()) continue
    const { tabs, spaces } = leading(line)
    if (tabs === 0 && spaces > 0 && (unit === 0 || spaces < unit)) unit = spaces
  }
  return unit || 4
}

/** Does the first line of a measure return text? (A literal, a text function, or a string concatenation.) */
function looksTextual(expression) {
  const e = expression.trim()
  if (e.startsWith('"')) return true
  if (/^(FORMAT|CONCATENATE|CONCATENATEX|COMBINEVALUES|UNICHAR|REPT|UPPER|LOWER|LEFT|RIGHT|MID|SUBSTITUTE|TRIM)\s*\(/i.test(e)) return true
  return /"\s*&|&\s*"/.test(e)
}

/** 'A quoted name' (doubled quotes inside) or a bare identifier, then the rest of the line. */
function readName(source) {
  const quoted = /^'((?:[^']|'')*)'\s*([\s\S]*)$/.exec(source)
  if (quoted) return { name: quoted[1].replace(/''/g, "'"), rest: quoted[2] }
  const bare = /^([^\s=]+)\s*([\s\S]*)$/.exec(source)
  if (bare) return { name: bare[1], rest: bare[2] }
  return null
}

function property(line) {
  const m = /^([A-Za-z]+)\s*:\s*(.*)$/.exec(line.trim())
  return m ? { key: m[1], value: m[2].trim() } : null
}

/** One table file. Returns null when the file holds no table. */
function parseTable(text) {
  let table = null
  let member = null
  let awaitingExpression = null
  const lines = text.replace(/^﻿/, '').split(/\r?\n/)
  const unit = spaceUnitOf(lines)
  for (const raw of lines) {
    if (!raw.trim()) continue
    const { tabs, spaces } = leading(raw)
    const depth = tabs + Math.floor(spaces / unit)
    const line = raw.trim()

    if (depth === 0) {
      if (line.startsWith('table ')) {
        const read = readName(line.slice('table '.length))
        if (read) table = { name: read.name, hidden: false, isDateTable: isDateTableName(read.name), columns: [], measures: [] }
      }
      member = null
      awaitingExpression = null
      continue
    }
    if (!table) continue

    // A measure whose expression starts on the next line: only its first line is looked at.
    if (depth >= 3 && awaitingExpression) {
      if (line !== '```') {
        if (looksTextual(line)) awaitingExpression.isText = true
        awaitingExpression = null
      }
      continue
    }

    if (depth === 1) {
      member = null
      awaitingExpression = null
      if (line.startsWith('column ')) {
        const read = readName(line.slice('column '.length))
        if (read) {
          const column = { name: read.name, dataType: 'string', hidden: false, imageUrl: false }
          table.columns.push(column)
          member = { kind: 'column', column }
        }
      } else if (line.startsWith('measure ')) {
        const read = readName(line.slice('measure '.length))
        if (read) {
          const expression = read.rest.replace(/^=\s*/, '')
          const measure = { name: read.name, isText: looksTextual(expression), hidden: false }
          table.measures.push(measure)
          member = { kind: 'measure', measure }
          if (expression === '' || expression === '```') awaitingExpression = measure
        }
      } else if (line === 'isHidden') {
        table.hidden = true
      } else {
        const prop = property(line)
        if (prop && prop.key === 'dataCategory' && /^time$/i.test(prop.value)) table.isDateTable = true
        member = { kind: 'other' }
      }
      continue
    }

    if (depth === 2 && member) {
      awaitingExpression = null
      if (member.kind === 'column') {
        if (line === 'isHidden') member.column.hidden = true
        const prop = property(line)
        if (!prop) continue
        if (prop.key === 'dataType') member.column.dataType = prop.value
        else if (prop.key === 'sortByColumn') member.column.sortByColumn = (readName(prop.value) || {}).name || prop.value
        else if (prop.key === 'dataCategory' && /^imageurl$/i.test(prop.value)) member.column.imageUrl = true
      } else if (member.kind === 'measure') {
        if (line === 'isHidden') member.measure.hidden = true
        const prop = property(line)
        if (prop && prop.key === 'formatString') member.measure.formatString = prop.value
      }
    }
  }
  return table
}

/** Fact.Key, 'Fact Sales'.'Date Key', 'Fact Sales'.Key: the table and the column. */
function readQualified(value) {
  const first = readName(value.trim())
  if (!first || !first.rest.startsWith('.')) {
    const bare = /^([^\s.']+)\.(.+)$/.exec(value.trim())
    if (!bare) return null
    const column = readName(bare[2])
    return column ? { table: bare[1], column: column.name } : null
  }
  const column = readName(first.rest.slice(1))
  return column ? { table: first.name, column: column.name } : null
}

/** The table pairs of relationships.tmdl. A relationship missing one side is ignored. */
function parseRelationships(text) {
  const out = []
  let current = null
  const flush = () => {
    if (current && current.fromTable && current.toTable) out.push({ fromTable: current.fromTable, toTable: current.toTable })
  }
  for (const raw of text.replace(/^﻿/, '').split(/\r?\n/)) {
    const line = raw.trim()
    if (!line) continue
    const lead = leading(raw)
    if (/^relationship\b/.test(line) && lead.tabs === 0 && lead.spaces === 0) {
      flush()
      current = {}
      continue
    }
    if (!current) continue
    const prop = property(line)
    if (!prop) continue
    if (prop.key === 'fromColumn' || prop.key === 'toColumn') {
      const ref = readQualified(prop.value)
      if (!ref) continue
      if (prop.key === 'fromColumn') current.fromTable = ref.table
      else current.toTable = ref.table
    }
  }
  flush()
  return out
}

function findModelFolder(input) {
  const p = resolve(input)
  if (!existsSync(p)) throw new Error(`Not found: ${p}`)
  if (/\.SemanticModel$/i.test(basename(p)) && statSync(p).isDirectory()) return p
  if (statSync(p).isDirectory()) {
    for (const entry of readdirSync(p)) {
      if (/\.SemanticModel$/i.test(entry) && statSync(join(p, entry)).isDirectory()) return join(p, entry)
    }
  }
  throw new Error(`No .SemanticModel folder found at ${p}. Point the script at <Name>.SemanticModel or at the folder that contains it.`)
}

/** The JSON, keys in a fixed order, false and empty values left out. */
function canonical(modelFolder, tables, relationships) {
  const out = { modelFolder }
  out.tables = tables.map((t) => {
    const o = { name: t.name }
    if (t.isDateTable) o.isDateTable = true
    if (t.hidden) o.hidden = true
    o.columns = t.columns.map((c) => {
      const col = { name: c.name, dataType: c.dataType }
      if (c.sortByColumn) col.sortByColumn = c.sortByColumn
      if (c.hidden) col.hidden = true
      if (c.imageUrl) col.imageUrl = true
      return col
    })
    o.measures = t.measures.map((m) => {
      const me = { name: m.name }
      if (m.formatString) me.formatString = m.formatString
      if (m.isText) me.isText = true
      if (m.hidden) me.hidden = true
      return me
    })
    return o
  })
  if (relationships) out.relationships = relationships
  return out
}

export function declarationsOf(folder) {
  const tablesDir = join(folder, 'definition', 'tables')
  if (!existsSync(tablesDir)) throw new Error(`No definition/tables folder in ${folder}. Is the model saved as a project (TMDL)?`)
  const tables = []
  const skipped = []
  const files = readdirSync(tablesDir).filter((f) => f.endsWith('.tmdl')).sort()
  for (const f of files) {
    const table = parseTable(readFileSync(join(tablesDir, f), 'utf8'))
    if (!table || AUTO_TABLE.test(table.name)) {
      skipped.push(f)
      continue
    }
    tables.push(table)
  }
  tables.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  const relPath = join(folder, 'definition', 'relationships.tmdl')
  const relationships = existsSync(relPath) ? parseRelationships(readFileSync(relPath, 'utf8')) : undefined
  return { declarations: canonical(basename(folder), tables, relationships), skipped }
}

function main(argv) {
  const args = argv.slice(2)
  let out = 'declarations.json'
  let input = null
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '-o' || args[i] === '--out') out = args[++i]
    else if (args[i] === '-h' || args[i] === '--help') input = null
    else input = args[i]
  }
  if (!input) {
    console.error('Usage: node export-declarations.mjs <path to .SemanticModel or project folder> [-o declarations.json]')
    process.exit(2)
  }
  const folder = findModelFolder(input)
  const { declarations, skipped } = declarationsOf(folder)
  writeFileSync(out, JSON.stringify(declarations, null, 2) + '\n', 'utf8')
  const columns = declarations.tables.reduce((n, t) => n + t.columns.length, 0)
  const measures = declarations.tables.reduce((n, t) => n + t.measures.length, 0)
  console.log(`${declarations.modelFolder}: ${declarations.tables.length} tables, ${columns} columns, ${measures} measures, ${declarations.relationships ? declarations.relationships.length + ' relationships' : 'no relationships.tmdl'}.`)
  for (const t of declarations.tables) console.log(`  ${t.name}: ${t.columns.length} columns, ${t.measures.length} measures${t.isDateTable ? ', date table' : ''}${t.hidden ? ', hidden' : ''}`)
  if (skipped.length) console.log(`  Skipped (automatic date tables or unreadable): ${skipped.join(', ')}`)
  console.log(`Written: ${resolve(out)}. Names only: no data, no DAX, no M. Open it, read it, then send it.`)
}

if (process.argv[1] && resolve(process.argv[1]) === new URL(import.meta.url).pathname) main(process.argv)
