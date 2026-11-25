const
  SHADER_SOURCE: AnsiString =
    'cbuffer Frame : register(b0) {'#10 +
    '  float2 pixelToClip; float depthScale; float crease;'#10 +
    '  float2 folds; float foldStyle; float printExposure;'#10 +
    '};'#10 +
    'Texture2D<float4> paperTex : register(t0);'#10 +
    'Texture2D<float4> caseTex : register(t1);'#10 +
    'SamplerState linearClamp : register(s0);'#10 +
    'struct Vertex {'#10 +
    '  float3 local : POSITION; float2 uv : TEXCOORD0;'#10 +
    '  float4 color : COLOR0; float2 surface : TEXCOORD1;'#10 +
    '};'#10 +
    'struct Fragment {'#10 +
    '  float4 pixel : SV_Position; float2 uv : TEXCOORD0;'#10 +
    '  float4 color : COLOR0; nointerpolation float material : TEXCOORD1;'#10 +
    '  float light : TEXCOORD2;'#10 +
    '};'#10 +
    'Fragment MeshVS(Vertex v) {'#10 +
    '  Fragment f;'#10 +
    '  f.pixel = float4(v.local.xy * pixelToClip, .5 - v.local.z * depthScale, 1);'#10 +
    '  f.uv = v.uv; f.color = v.color; f.material = v.surface.x; f.light = v.surface.y;'#10 +
    '  return f;'#10 +
    '}'#10 +
    'float foldLine(float t, float n) {'#10 +
    '  float x = t * n; float closest = round(x);'#10 +
    '  if (closest < 1 || closest >= n) return 0;'#10 +
    '  float d = (x - closest) / max(fwidth(x), n * .0005);'#10 +
    '  return -0.23 * exp(-d*d*.55) + 0.11 * exp(-pow(abs(d-1.6),2)*.7);'#10 +
    '}'#10 +
    'float4 MeshPS(Fragment f, bool front : SV_IsFrontFace) : SV_Target {'#10 +
    '  float4 c = float4(f.color.rgb * f.color.a, f.color.a);'#10 +
    '  if (f.material > 1.5) return caseTex.Sample(linearClamp, f.uv) * f.color.a;'#10 +
    '  if (f.material < .5) return c;'#10 +
    '  float4 image = paperTex.Sample(linearClamp, f.uv);'#10 +
    '  float4 surface = lerp(float4(f.color.rgb, 1), image, printExposure);'#10 +
    '  clip(surface.a * c.a - .001);'#10 +
    '  if (!front) surface.rgb = f.color.rgb * surface.a;'#10 +
    '  c = surface * f.color.a;'#10 +
    '  float mark = 0;'#10 +
    '  if (crease * printExposure > 0) {'#10 +
    '    mark = foldLine(f.uv.x, folds.x) + foldLine(f.uv.y, folds.y);'#10 +
    '    if (foldStyle == 10) {'#10 +
    '      mark += .54 * foldLine(.5 * (f.uv.x + f.uv.y), 7);'#10 +
    '      mark += .45 * foldLine(.5 + .5 * (f.uv.x - f.uv.y), 9);'#10 +
    '    }'#10 +
    '  }'#10 +
    '  float light = f.light + crease * printExposure * mark;'#10 +
    '  return float4(min(c.rgb * light, c.a), c.a);'#10 +
    '}'#10 +
    'float4 CopyVS(uint i : SV_VertexID) : SV_Position {'#10 +
    '  return float4(i == 2 ? 3 : -1, i == 1 ? -3 : 1, 0, 1);'#10 +
    '}'#10 +
    'float4 CopyPS(float4 pixel : SV_Position) : SV_Target {'#10 +
    '  return paperTex.Load(int3(int2(pixel.xy), 0));'#10 +
    '}'#10 +
    'float4 ReadbackPS(float4 pixel : SV_Position) : SV_Target {'#10 +
    '  float4 c = paperTex.Load(int3(int2(pixel.xy), 0));'#10 +
    '  return (c.a > .00001) ? float4(saturate(c.rgb / c.a), c.a) : 0;'#10 +
    '}';
