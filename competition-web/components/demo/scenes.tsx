"use client";

import { Canvas, useFrame, useThree } from "@react-three/fiber";
import { useEffect, useMemo, useRef, useState } from "react";
import * as THREE from "three";
import { PerspectiveCamera } from "@react-three/drei";

const rankColors = ["#d9a83e", "#e5799c", "#b86b4d"];

function seededValue(seed: string, position: number) {
  const char = seed.charCodeAt(position % Math.max(1, seed.length)) || position;
  return ((char * 31 + position * 67 + seed.length * 19) % 997) / 997;
}

function artworkTexture(seed: string) {
  const canvas = document.createElement("canvas");
  canvas.width = 512;
  canvas.height = 720;
  const context = canvas.getContext("2d")!;
  const hue = Math.floor(seededValue(seed, 0) * 360);
  const gradient = context.createLinearGradient(0, 0, 420, 720);
  gradient.addColorStop(0, `hsl(${hue} 55% 23%)`);
  gradient.addColorStop(1, `hsl(${(hue + 46) % 360} 48% 10%)`);
  context.fillStyle = gradient;
  context.fillRect(0, 0, 512, 720);
  for (let i = 0; i < 9; i++) {
    const x = seededValue(seed, i + 2) * 580 - 40;
    const y = seededValue(seed, i + 13) * 720;
    const radius = 45 + seededValue(seed, i + 23) * 155;
    context.beginPath();
    context.ellipse(
      x,
      y,
      radius * 0.65,
      radius,
      seededValue(seed, i + 38),
      0,
      Math.PI * 2,
    );
    context.fillStyle = `hsla(${(hue + i * 21) % 360} 76% ${44 + (i % 3) * 8}% / ${0.13 + (i % 4) * 0.035})`;
    context.fill();
  }
  context.fillStyle = "rgba(255,255,255,.10)";
  for (let i = 0; i < 12; i++) {
    context.fillRect(30 + i * 37, 40, 1, 640);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return texture;
}

function Sleeve({
  seed,
  position,
  rotation = 0,
  scale = 1,
}: {
  seed: string;
  position: [number, number, number];
  rotation?: number;
  scale?: number;
}) {
  const map = useMemo(() => artworkTexture(seed), [seed]);
  useEffect(() => () => map.dispose(), [map]);
  return (
    <group position={position} rotation={[0, rotation, 0]} scale={scale}>
      <mesh castShadow>
        <boxGeometry args={[1.55, 2.18, 0.085]} />
        <meshStandardMaterial color="#17191a" roughness={0.8} />
      </mesh>
      <mesh position={[0, 0, 0.045]}>
        <planeGeometry args={[1.48, 2.11]} />
        <meshStandardMaterial map={map} roughness={0.9} />
      </mesh>
      <mesh position={[0, -0.81, 0.052]}>
        <planeGeometry args={[1.1, 0.018]} />
        <meshBasicMaterial color="#69b58d" transparent opacity={0.8} />
      </mesh>
      <mesh position={[0, 0, -0.05]}>
        <planeGeometry args={[1.48, 2.11]} />
        <meshBasicMaterial color="#101212" />
      </mesh>
    </group>
  );
}

function Lights() {
  return (
    <>
      <ambientLight intensity={1.6} />
      <directionalLight position={[2, 4, 5]} intensity={2.1} />
      <pointLight
        position={[-3, -1, 2]}
        color="#69b58d"
        intensity={10}
        distance={9}
      />
    </>
  );
}

export function IntroScene({ index }: { index: number }) {
  return (
    <Canvas
      dpr={[1, 2]}
      frameloop="demand"
      camera={{ position: [0, 0, 6], fov: 38 }}
      gl={{ antialias: true, alpha: true, powerPreference: "low-power" }}
      aria-hidden="true"
    >
      <PerspectiveCamera makeDefault position={[0, 0, 6]} fov={38} />
      <Lights />
      {[-2, -1, 1, 2].map((offset) => (
        <Sleeve
          key={`${index}-${offset}`}
          seed={`sleeve-${index + offset}`}
          position={[
            offset * 0.31,
            -0.06 + Math.abs(offset) * 0.045,
            -0.25 + Math.abs(offset) * -0.035,
          ]}
          rotation={offset * -0.13}
          scale={0.89}
        />
      ))}
      <Sleeve
        seed={`sleeve-${index}`}
        position={[0, 0, 0.1]}
        rotation={-0.04}
      />
    </Canvas>
  );
}

function Vinyl({
  entryId,
  playing,
  analyser,
}: {
  entryId: string;
  playing: boolean;
  analyser: AnalyserNode | null;
}) {
  const record = useRef<THREE.Group>(null);
  const ring = useRef<THREE.Mesh>(null);
  const data = useMemo(() => new Uint8Array(64), []);
  const texture = useMemo(() => artworkTexture(entryId), [entryId]);
  useEffect(() => () => texture.dispose(), [texture]);
  useFrame((_, delta) => {
    if (!playing) return;
    const level = analyser
      ? (analyser.getByteFrequencyData(data), data[4] / 255)
      : 0.2;
    if (record.current) record.current.rotation.z -= delta * 1.8;
    if (ring.current) {
      const mesh = ring.current;
      mesh.scale.setScalar(1 + level * 0.12);
      const material = mesh.material as THREE.MeshBasicMaterial;
      material.opacity = 0.45 + level * 0.35;
    }
  });
  return (
    <group ref={record} rotation={[0.35, -0.1, 0.16]}>
      <mesh castShadow>
        <cylinderGeometry args={[1.8, 1.8, 0.08, 96]} />
        <meshStandardMaterial
          color="#131516"
          roughness={0.42}
          metalness={0.18}
        />
      </mesh>
      {[1.67, 1.49, 1.3, 1.1, 0.89].map((radius) => (
        <mesh
          key={radius}
          rotation={[Math.PI / 2, 0, 0]}
          position={[0, 0.047, 0]}
        >
          <torusGeometry args={[radius, 0.008, 6, 96]} />
          <meshBasicMaterial color="#535758" transparent opacity={0.55} />
        </mesh>
      ))}
      <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.052, 0]}>
        <circleGeometry args={[0.77, 64]} />
        <meshStandardMaterial map={texture} roughness={0.82} />
      </mesh>
      <mesh position={[0, 0.06, 0]}>
        <cylinderGeometry args={[0.09, 0.09, 0.03, 32]} />
        <meshStandardMaterial
          color="#cfc7ac"
          metalness={0.45}
          roughness={0.35}
        />
      </mesh>
      <mesh ref={ring} rotation={[Math.PI / 2, 0, 0]} position={[0, 0.04, 0]}>
        <torusGeometry args={[2.04, 0.035, 8, 96]} />
        <meshBasicMaterial color="#69b58d" transparent opacity={0.55} />
      </mesh>
    </group>
  );
}

export function VinylScene({
  entryId,
  playing,
  analyser,
}: {
  entryId: string;
  playing: boolean;
  analyser: AnalyserNode | null;
}) {
  return (
    <Canvas
      dpr={[1, 2]}
      frameloop={playing ? "always" : "demand"}
      camera={{ position: [0, 0, 5.8], fov: 42 }}
      gl={{ antialias: true, alpha: true, powerPreference: "low-power" }}
      aria-hidden="true"
    >
      <PerspectiveCamera makeDefault position={[0, 0, 5.8]} fov={42} />
      <Lights />
      <Vinyl entryId={entryId} playing={playing} analyser={analyser} />
    </Canvas>
  );
}

function RevealAnimation({ entryId, rank }: { entryId: string; rank: number }) {
  const sleeve = useRef<THREE.Group>(null);
  const record = useRef<THREE.Group>(null);
  const gem = useRef<THREE.Mesh>(null);
  const start = useRef(0);
  const { invalidate } = useThree();
  const color = rankColors[(rank - 1) % rankColors.length];
  const dust = useMemo(
    () =>
      Array.from(
        { length: 22 },
        (_, i) =>
          [
            (seededValue(entryId, i + 2) - 0.5) * 3.3,
            (seededValue(entryId, i + 24) - 0.5) * 2.6,
            (seededValue(entryId, i + 46) - 0.5) * 0.8,
          ] as [number, number, number],
      ),
    [entryId],
  );
  useFrame((state) => {
    if (!start.current) start.current = state.clock.elapsedTime;
    const t = Math.min((state.clock.elapsedTime - start.current) / 2.4, 1);
    if (sleeve.current)
      sleeve.current.rotation.y = (1 - Math.min(t * 1.6, 1)) * Math.PI;
    if (record.current)
      record.current.position.x = -0.75 + Math.min(t * 1.4, 1) * 0.75;
    if (gem.current) {
      gem.current.position.y = -0.58 + Math.max(0, t - 0.4) * 0.64;
      gem.current.rotation.y += 0.012;
      gem.current.scale.setScalar(
        Math.min(0.18 + Math.max(0, t - 0.35) * 1.05, 0.86),
      );
    }
    if (t < 1) invalidate();
  });
  return (
    <>
      <Lights />
      {dust.map(([x, y, z], i) => (
        <mesh key={i} position={[x, y, z]} scale={i % 4 === 0 ? 0.035 : 0.018}>
          <icosahedronGeometry args={[1, 0]} />
          <meshBasicMaterial color={color} transparent opacity={0.68} />
        </mesh>
      ))}
      <group ref={record} position={[-0.75, 0, -0.1]}>
        <mesh rotation={[Math.PI / 2, 0, 0]}>
          <cylinderGeometry args={[0.78, 0.78, 0.045, 64]} />
          <meshStandardMaterial
            color="#111314"
            roughness={0.4}
            metalness={0.2}
          />
        </mesh>
        <mesh rotation={[Math.PI / 2, 0, 0]} position={[0, 0.03, 0]}>
          <circleGeometry args={[0.3, 48]} />
          <meshStandardMaterial map={artworkTexture(entryId)} />
        </mesh>
      </group>
      <group ref={sleeve} position={[0.15, 0, 0.25]}>
        <Sleeve seed={entryId} position={[0, 0, 0]} scale={0.85} />
      </group>
      <mesh ref={gem} position={[0.6, -0.58, 0.35]} scale={0.18}>
        <octahedronGeometry args={[0.58, 0]} />
        <meshPhysicalMaterial
          color={color}
          roughness={0.24}
          metalness={0.32}
          clearcoat={0.75}
        />
      </mesh>
    </>
  );
}

export function RevealScene({
  entryId,
  rank,
  visible,
}: {
  entryId: string;
  rank: number;
  visible: boolean;
}) {
  const [animate, setAnimate] = useState(true);
  useEffect(() => {
    const timer = window.setTimeout(() => setAnimate(false), 2700);
    return () => window.clearTimeout(timer);
  }, [entryId, rank]);
  return (
    <Canvas
      dpr={[1, 2]}
      frameloop={animate && visible ? "always" : "demand"}
      camera={{ position: [0, 0, 6], fov: 40 }}
      gl={{ antialias: true, alpha: true, powerPreference: "low-power" }}
      aria-hidden="true"
    >
      <PerspectiveCamera makeDefault position={[0, 0, 6]} fov={40} />
      <RevealAnimation entryId={entryId} rank={rank} />
    </Canvas>
  );
}
