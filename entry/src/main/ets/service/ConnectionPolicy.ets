/**
 * ConnectionPolicy.ets — GPS delivery cadence selected by the user.
 *
 * The policy is application-wide because Location Kit and the GPS ticker are
 * shared across every connected camera. Per-camera cadence would make a
 * multi-camera session fight over the same location source and BLE radio.
 */
export enum ConnectionPolicy {
  PowerSaving = 'power_saving',
  Balanced = 'balanced',
  Stable = 'stable',
  Auto = 'auto',
}

export function isConnectionPolicy(value: string): boolean {
  return value === ConnectionPolicy.PowerSaving
    || value === ConnectionPolicy.Balanced
    || value === ConnectionPolicy.Stable
    || value === ConnectionPolicy.Auto;
}

export function connectionPolicyLabel(policy: ConnectionPolicy): string {
  if (policy === ConnectionPolicy.PowerSaving) return '省电';
  if (policy === ConnectionPolicy.Balanced) return '均衡';
  if (policy === ConnectionPolicy.Stable) return '稳定';
  return '自动';
}

export function connectionPolicyDescription(policy: ConnectionPolicy): string {
  if (policy === ConnectionPolicy.PowerSaving) return '降低定位与蓝牙写入频率，适合长时间待机。';
  if (policy === ConnectionPolicy.Balanced) return '兼顾位置更新速度与续航，适合日常拍摄。';
  if (policy === ConnectionPolicy.Stable) return '更高频地获取位置并下发，优先保证连续性。';
  return '根据定位质量、移动速度和前后台状态自动调整频率。';
}
