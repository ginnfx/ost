import type { Metadata } from 'next';
import { DemoApp } from '@/components/demo-app';
import './demo.css';

export const metadata: Metadata = {
  title: 'OST Competition',
  description: 'Private soundtrack competition preview.',
  robots: { index: false, follow: false, noarchive: true },
  openGraph: { title: 'OST Competition', description: 'Private soundtrack competition preview.', type: 'website' },
};

export default function DemoPage() { return <DemoApp/>; }
