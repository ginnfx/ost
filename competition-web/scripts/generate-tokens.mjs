import fs from 'node:fs';
const tokens = JSON.parse(fs.readFileSync(new URL('../tokens.json', import.meta.url)));
const css = (name, value) => `  --${name}: ${value};`;
const lines = [':root {', ...Object.entries(tokens.colors.dark).map(([k,v]) => css(k,v)), css('accent',tokens.colors.accent), css('gold',tokens.colors.gold), css('pink',tokens.colors.pink), css('rust',tokens.colors.rust), `  --radius-sm: ${tokens.geometry.radii[0]}px;`, `  --radius-md: ${tokens.geometry.radii[1]}px;`, `  --radius-lg: ${tokens.geometry.radii[3]}px;`, `  --space: 4px;`, '  color-scheme: dark;', '}', '@media (prefers-color-scheme: light) {', '  :root {', ...Object.entries(tokens.colors.light).map(([k,v]) => css(k,v)), '    color-scheme: light;', '  }', '}'];
fs.writeFileSync(new URL('../app/tokens.generated.css', import.meta.url), `${lines.join('\n')}\n`);
