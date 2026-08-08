import { ApiClientError } from './api'

const PURCHASE_URL = 'https://pay.ldxp.cn/shop/7CX09W5E'

export function handleCreditsRequired(reason: unknown): boolean {
  if (!(reason instanceof ApiClientError) || reason.code !== 'CREDITS_INSUFFICIENT') return false
  const balance = typeof reason.details.balance === 'number' ? reason.details.balance : null
  const required = typeof reason.details.required === 'number' ? reason.details.required : null
  const detail = balance !== null && required !== null
    ? `当前可用 ${balance.toFixed(5)} credits，本次至少需要 ${required.toFixed(5)} credits。`
    : '当前 credits 不足。'
  if (window.confirm(`${detail}\n需要先兑换 credits。是否前往购买页面？`)) window.location.assign(PURCHASE_URL)
  return true
}
