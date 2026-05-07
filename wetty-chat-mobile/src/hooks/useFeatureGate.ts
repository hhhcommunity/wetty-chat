import { type Feature, isFeatureEnabled } from '@/features';

export function useFeatureGate(feature: Feature): boolean {
  return isFeatureEnabled(feature);
}
