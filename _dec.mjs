import fs from 'node:fs';

const SRC = process.argv[2];
const OUT = process.argv[3];
const filter = process.argv[4];

const p = JSON.parse(fs.readFileSync(SRC, 'utf8'));
const targets = filter ? (Array.isArray(p) ? p : [p]).filter(t => filter.split('|').some(n => t.name === n)) : (Array.isArray(p) ? p : [p]);

const VARNAME = new Map(), LISTNAME = new Map(), BCASTNAME = new Map();
for (const t of targets) {
  for (const [id, v] of Object.entries(t.variables || {})) VARNAME.set(id, v[0]);
  for (const [id, v] of Object.entries(t.lists || {})) LISTNAME.set(id, v[0]);
  for (const [id, v] of Object.entries(t.broadcasts || {})) BCASTNAME.set(id, v);
}

const OPBIN = {
  operator_add: '+', operator_subtract: '-', operator_multiply: '*', operator_divide: '/',
  operator_mod: 'mod', operator_equals: '=', operator_lt: '<', operator_gt: '>',
  operator_and: 'and', operator_or: 'or', operator_join: 'join',
};
const UNARY_ARG_KEY = {
  operator_round: 'NUM', operator_not: 'OPERAND', operator_length: 'STRING',
  operator_mathop: 'NUM',
};
const BIN_ARG_KEY = {
  operator_add: ['NUM1', 'NUM2'], operator_subtract: ['NUM1', 'NUM2'],
  operator_multiply: ['NUM1', 'NUM2'], operator_divide: ['NUM1', 'NUM2'],
  operator_mod: ['NUM1', 'NUM2'], operator_equals: ['OPERAND1', 'OPERAND2'],
  operator_lt: ['OPERAND1', 'OPERAND2'], operator_gt: ['OPERAND1', 'OPERAND2'],
  operator_and: ['OPERAND1', 'OPERAND2'], operator_or: ['OPERAND1', 'OPERAND2'],
  operator_join: ['STRING1', 'STRING2'],
};
const FIELDED = {
  operator_mathop: (b) => `${b.fields?.OPERATOR?.[0]}(@1)`,
  data_itemoflist: (b) => `item @1 of ${b.fields?.LIST?.[0]}`,
  data_itemnumoflist: (b) => `item # of @1 in ${b.fields?.LIST?.[0]}`,
  data_lengthoflist: (b) => `length of ${b.fields?.LIST?.[0]}`,
  sensing_touchingobject: () => `touching @1?`,
  sensing_distanceto: () => `distance to @1`,
  sensing_keypressed: () => `key @1 pressed?`,
  sensing_of: (b) => `${b.fields?.PROPERTY?.[0]} of @1`,
  looks_costumenumbername: (b) => `costume ${b.fields?.NUMBER_NAME?.[0]}`,
  motion_xposition: () => 'x position',
  motion_yposition: () => 'y position',
  sensing_mousex: () => 'mouse x',
  sensing_mousey: () => 'mouse y',
  sensing_answer: () => 'answer',
  sound_sounds_menu: (b) => `${b.fields?.SOUND_MENU?.[0]}`,
  motion_goto_menu: (b) => `${b.fields?.TO?.[0]}`,
  motion_pointtowards_menu: (b) => `${b.fields?.TOWARDS?.[0]}`,
  sensing_of_object_menu: (b) => `${b.fields?.OBJECT?.[0]}`,
  control_create_clone_of_menu: (b) => `${b.fields?.CLONE_OPTION?.[0]}`,
  sensing_distancetomenu: (b) => `${b.fields?.DISTANCETOMENU?.[0]}`,
  sensing_touchingobjectmenu: (b) => `${b.fields?.TOUCHINGOBJECTMENU?.[0]}`,
  looks_costume: (b) => `${b.fields?.COSTUME?.[0]}`,
  looks_backdrops: (b) => `${b.fields?.NUMBER_NAME?.[0]}`,
  event_whenkeypressed: (b) => `key [${b.fields?.KEY_OPTION?.[0]}]`,
};

function isBlockRef(v, bl) {
  if (typeof v === 'string' && bl[v]) return v;
  return null;
}
function inputOf(b, key, bl) {
  const inp = b.inputs?.[key];
  if (!inp) return null;
  const v1 = inp[1], v2 = inp[2];
  if (typeof v1 === 'string' && bl[v1]) return render(bl[v1], bl, 0);
  if (Array.isArray(v1)) return prim(v1);
  if (v2 !== undefined) {
    if (typeof v2 === 'string' && bl[v2]) return render(bl[v2], bl, 0);
    if (Array.isArray(v2)) return prim(v2);
  }
  return v1 === undefined ? '?' : String(v1);
}
function prim(v) {
  if (!Array.isArray(v)) return v === undefined ? '?' : String(v);
  const kind = v[0];
  if (kind === 12) return VARNAME.get(v[2]) ?? v[1] ?? '?';
  if (kind === 13) return LISTNAME.get(v[2]) ?? v[1] ?? '?';
  if (kind === 11) return BCASTNAME.get(v[2]) ?? v[1] ?? '?';
  return String(v[1]);
}
function field(b, n) { const f = b.fields?.[n]; return f ? f[0] : undefined; }

function render(b, bl, depth) {
  if (!b || !b.opcode) return '';
  const ind = '  '.repeat(depth);
  const I = (n) => inputOf(b, n, bl);
  const op = b.opcode;

  if (BIN_ARG_KEY[op]) {
    const [a, c] = BIN_ARG_KEY[op];
    const l = I(a), r = I(c);
    if (op === 'operator_join') return `${ind}join(${l}, ${r})`;
    return `${ind}(${l} ${OPBIN[op]} ${r})`;
  }
  if (UNARY_ARG_KEY[op]) {
    const a = I(UNARY_ARG_KEY[op]);
    if (op === 'operator_mathop') return `${ind}${field(b, 'OPERATOR')}(${a})`;
    if (op === 'operator_not') return `${ind}not(${a})`;
    return `${ind}round(${a})`;
  }
  if (op === 'operator_random') return `${ind}random(${I('FROM')}, ${I('TO')})`;
  if (FIELDED[op]) {
    let s = FIELDED[op](b);
    for (const k of Object.keys(b.inputs || {})) s = s.replace('@1', I(k));
    return `${ind}${s}`;
  }

  switch (op) {
    case 'event_whenflagclicked': return `${ind}when FLAG:`;
    case 'event_whenbroadcastreceived': return `${ind}when I receive [${field(b, 'BROADCAST_OPTION')}]:`;
    case 'event_broadcast': return `${ind}broadcast [${I('BROADCAST_INPUT')}]`;
    case 'event_broadcastandwait': return `${ind}broadcast and wait [${I('BROADCAST_INPUT')}]`;
    case 'event_whenkeypressed': return `${ind}when key [${field(b, 'KEY_OPTION')}] pressed:`;
    case 'event_whenthisspriteclicked': return `${ind}when this sprite clicked:`;
    case 'control_start_as_clone': return `${ind}when I start as a clone:`;
    case 'control_if': return `${ind}if ${I('CONDITION')}:\n${sub(b, 'SUBSTACK', depth + 1, bl)}`;
    case 'control_if_else': return `${ind}if ${I('CONDITION')}:\n${sub(b, 'SUBSTACK', depth + 1, bl)}${ind}else:\n${sub(b, 'SUBSTACK2', depth + 1, bl)}`;
    case 'control_forever': return `${ind}forever:\n${sub(b, 'SUBSTACK', depth + 1, bl)}`;
    case 'control_repeat': return `${ind}repeat(${I('TIMES')}):\n${sub(b, 'SUBSTACK', depth + 1, bl)}`;
    case 'control_repeat_until': return `${ind}repeat until ${I('CONDITION')}:\n${sub(b, 'SUBSTACK', depth + 1, bl)}`;
    case 'control_wait': return `${ind}wait(${I('DURATION')})`;
    case 'control_wait_until': return `${ind}wait until ${I('CONDITION')}`;
    case 'control_stop': return `${ind}stop [${field(b, 'STOP_OPTION')}]`;
    case 'control_create_clone_of': return `${ind}create clone of ${I('CLONE_OPTION')}`;
    case 'control_delete_this_clone': return `${ind}delete this clone`;
    case 'data_setvariableto': return `${ind}set ${field(b, 'VARIABLE')} = ${I('VALUE')}`;
    case 'data_changevariableby': return `${ind}change ${field(b, 'VARIABLE')} by ${I('VALUE')}`;
    case 'data_showvariable': return `${ind}show var ${field(b, 'VARIABLE')}`;
    case 'data_hidevariable': return `${ind}hide var ${field(b, 'VARIABLE')}`;
    case 'data_addtolist': return `${ind}add ${I('ITEM')} to ${field(b, 'LIST')}`;
    case 'data_deleteoflist': return `${ind}delete ${I('INDEX')} of ${field(b, 'LIST')}`;
    case 'data_deletealloflist': return `${ind}delete all of ${field(b, 'LIST')}`;
    case 'data_replaceitemoflist': return `${ind}replace item ${I('INDEX')} of ${field(b, 'LIST')} with ${I('ITEM')}`;
    case 'looks_say': return `${ind}say ${I('MESSAGE')}`;
    case 'looks_show': return `${ind}show`;
    case 'looks_hide': return `${ind}hide`;
    case 'looks_setsizeto': return `${ind}set size ${I('SIZE')}%`;
    case 'looks_seteffectto': return `${ind}set [${field(b, 'EFFECT')}] effect to ${I('VALUE')}`;
    case 'looks_changeeffectby': return `${ind}change [${field(b, 'EFFECT')}] effect by ${I('CHANGE')}`;
    case 'looks_cleargraphiceffects': return `${ind}clear graphic effects`;
    case 'looks_switchcostumeto': return `${ind}switch costume to ${I('COSTUME')}`;
    case 'looks_gotofrontback': return `${ind}go to ${field(b, 'FRONT_BACK')} layer`;
    case 'looks_goforwardbackwardlayers': return `${ind}go ${field(b, 'FORWARD_BACKWARD')} ${I('NUM')} layers`;
    case 'motion_gotoxy': return `${ind}go to x:${I('X')} y:${I('Y')}`;
    case 'motion_goto': return `${ind}go to ${I('TO')}`;
    case 'motion_glidesecstoxy': return `${ind}glide ${I('SECS')}s to x:${I('X')} y:${I('Y')}`;
    case 'motion_movesteps': return `${ind}move ${I('STEPS')} steps`;
    case 'motion_changexby': return `${ind}change x by ${I('DX')}`;
    case 'motion_changeyby': return `${ind}change y by ${I('DY')}`;
    case 'motion_turnright': return `${ind}turn right ${I('DEGREES')} deg`;
    case 'motion_pointtowards': return `${ind}point towards ${I('TOWARDS')}`;
    case 'pen_penDown': return `${ind}pen down`;
    case 'pen_penUp': return `${ind}pen up`;
    case 'pen_clear': return `${ind}erase all`;
    case 'pen_stamp': return `${ind}stamp`;
    case 'pen_setPenColorToColor': return `${ind}set pen color to ${I('COLOR')}`;
    case 'sound_play': return `${ind}start sound ${I('SOUND_MENU')}`;
    case 'sound_playuntildone': return `${ind}play sound ${I('SOUND_MENU')} until done`;
    case 'procedures_definition': {
      const protoId = b.inputs?.custom_block?.[1];
      const proto = bl[protoId];
      return `${ind}DEFINE ${proto?.mutation?.proccode || '?'}`;
    }
    case 'procedures_call': {
      const code = b.mutation?.proccode || '?';
      const ids = JSON.parse(b.mutation?.argumentids || '[]');
      const args = ids.map((id) => inputOf(b, id, bl));
      return `${ind}CALL ${code}${args.length ? '  args=[' + args.join(', ') + ']' : ''}`;
    }
    case 'argument_reporter_string_number': return `${ind}${field(b, 'VALUE')}`;
    case 'argument_reporter_boolean': return `${ind}${field(b, 'VALUE')}`;
    default: {
      const ins = Object.entries(b.inputs || {}).map(([k]) => `${k}=${inputOf(b, k, bl)}`).join(' ');
      const fds = Object.entries(b.fields || {}).map(([k, v]) => `${k}=${v[0]}`).join(' ');
      return `${ind}<${op}${ins ? ' ' + ins : ''}${fds ? ' | ' + fds : ''}>`;
    }
  }
}

function sub(b, name, depth, bl) {
  const inp = b.inputs?.[name];
  if (!inp || typeof inp[1] !== 'string') return `${'  '.repeat(depth)}<empty>\n`;
  let id = inp[1], out = '', guard = 0;
  while (id && bl[id] && guard++ < 20000) {
    out += render(bl[id], bl, depth) + '\n';
    id = bl[id].next || null;
  }
  return out;
}

const out = [];
for (const t of targets) {
  out.push(`\n${'='.repeat(78)}\n# ${t.name}${t.isStage ? '  (STAGE)' : ''}\n${'='.repeat(78)}`);
  const bl = t.blocks || {};
  const tops = Object.entries(bl).filter(([, b]) => b && b.topLevel);
  for (const [, b] of tops) {
    out.push(render(b, bl, 0));
    let cur = b.next, guard = 0;
    while (cur && bl[cur] && guard++ < 20000) { out.push(render(bl[cur], bl, 1)); cur = bl[cur].next || null; }
    out.push('');
  }
}
fs.writeFileSync(OUT, out.join('\n'), 'utf8');
console.log('wrote', OUT, 'lines', out.length);
