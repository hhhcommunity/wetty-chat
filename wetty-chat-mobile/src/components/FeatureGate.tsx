import React from 'react';
import type { Feature } from '@/features';
import { useFeatureGate } from '@/hooks/useFeatureGate';

interface FeatureGateProps {
  feature: Feature;
  children: React.ReactNode;
  fallback?: React.ReactNode;
}

export const FeatureGate: React.FC<FeatureGateProps> = ({ feature, children, fallback = null }) => {
  const isEnabled = useFeatureGate(feature);
  return isEnabled ? children : fallback;
};
