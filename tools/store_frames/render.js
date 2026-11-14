// node render.js <shotsDir> <outDir> [langs...]
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const caps = JSON.parse(fs.readFileSync(__dirname + '/captions.json'));
// u = scale unit (1 unit ≈ 1 px at 430pt-wide phone design)
const STORES = {
  apple: { w: 1320, h: 2868, u: 3.07, top: 66, fs: 40, ss: 17, pt: 222, phh: 684 },
  play:  { w: 1080, h: 1920, u: 2.5, top: 34, fs: 34, ss: 15, pt: 170, phh: 590 },
};
(async () => {
  const [shots, out, ...langsArg] = process.argv.slice(2);
  const langs = langsArg.length ? langsArg : ['ru','en','uk','es','pt','de','fr','it'];
  const b = await chromium.launch();
  for (const [store, S] of Object.entries(STORES)) {
    const p = await b.newPage({ viewport: { width: S.w, height: S.h } });
    for (const lang of langs) for (const key of Object.keys(caps)) {
      const img = path.resolve(shots, `${lang}_${key}.png`);
      if (!fs.existsSync(img)) { console.log('skip', img); continue; }
      const [t, s] = caps[key][lang];
      const url = 'file://' + __dirname + '/frame.html?' + new URLSearchParams({ t, s, img: 'file://' + img });
      await p.goto(url);
      await p.addStyleTag({ content: `:root{--w:${S.w}px;--h:${S.h}px;--u:${S.u};--top:${S.top};--fs:${S.fs};--ss:${S.ss};--pt:${S.pt};--phh:${S.phh}}` });
      await p.evaluate(async () => { await document.fonts.ready; const i = document.getElementById('i'); if (!i.complete) await new Promise(r => i.onload = r); fit(); });
      const dir = path.join(out, store, lang); fs.mkdirSync(dir, { recursive: true });
      await p.screenshot({ path: path.join(dir, `${key}.png`) });
    }
  }
  await b.close();
})();
