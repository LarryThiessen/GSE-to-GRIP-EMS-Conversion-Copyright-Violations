import { NextRequest, NextResponse } from 'next/server'
import { convertGSEExportToGRIP } from '@/lib/workshop/index'
import { checkRateLimit, getClientIp } from '@/lib/rate-limit'

export async function POST(req: NextRequest) {
  const ip = getClientIp(req)
  if (!checkRateLimit(`workshop-convert:${ip}`, { limit: 30, windowMs: 60_000 })) {
    return NextResponse.json({ error: 'Too many requests. Please slow down and try again shortly.' }, { status: 429 })
  }

  let body: { code?: string }
  try { body = await req.json() } catch { return NextResponse.json({ error: 'Invalid JSON body.' }, { status: 400 }) }

  const { code } = body
  if (!code || typeof code !== 'string') return NextResponse.json({ error: 'code is required.' }, { status: 400 })

  if (!/^!GSE3!/i.test(code.trim())) {
    return NextResponse.json({ error: 'Convert expects a !GSE3! export code.' }, { status: 422 })
  }

  try {
    const result = convertGSEExportToGRIP(code.trim())
    return NextResponse.json(result)
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Failed to convert export.'
    return NextResponse.json({ error: message }, { status: 422 })
  }
}
