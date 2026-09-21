"""Small lossless Lua lexer for recovery tooling. Byte-preserving source offsets."""
from dataclasses import dataclass
import re

@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int

class SyntaxFailure(ValueError): pass
NUM = re.compile(r'(?:0[xX][0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)')
NAME = re.compile(r'[a-zA-Z_][a-zA-Z_0-9]*')
LONG = re.compile(r'\[(=*)\[')
MULTI = ('...', '..=', '//=', '+=','-=','*=','/=','%=','^=','==','~=','<=','>=','..','//','::','->')

def lex(source):
    out=[]; i=0; n=len(source)
    while i<n:
        a=i; c=source[i]
        if c.isspace(): i+=1; continue
        if source.startswith('--',i):
            m=LONG.match(source,i+2)
            if m:
                end=source.find(']'+m[1]+']',m.end())
                if end<0: raise SyntaxFailure('Unterminated long comment')
                i=end+len(m[1])+2
            else:
                end=source.find('\n',i+2); i=n if end<0 else end
            continue
        if c in '\"\'':
            quote=c; i+=1
            while i<n:
                if source[i]=='\\': i+=2; continue
                if source[i]==quote: i+=1; break
                i+=1
            else: raise SyntaxFailure('Unterminated string')
            out.append(Token('str',source[a:i],a,i)); continue
        m=LONG.match(source,i)
        if m:
            end=source.find(']'+m[1]+']',m.end())
            if end<0: raise SyntaxFailure('Unterminated long string')
            i=end+len(m[1])+2; out.append(Token('str',source[a:i],a,i)); continue
        if c.isdigit() or c=='.' and i+1<n and source[i+1].isdigit():
            m=NUM.match(source,i); i=m.end(); out.append(Token('num',m[0],a,i)); continue
        m=NAME.match(source,i)
        if m: i=m.end(); out.append(Token('name',m[0],a,i)); continue
        op=next((op for op in MULTI if source.startswith(op,i)),c)
        i+=len(op); out.append(Token('op',op,a,i))
    out.append(Token('eof','<eof>',n,n)); return out

def number(text):
    return float.fromhex(text) if text.lower().startswith('0x') else float(text)

def decode_string(text):
    m=LONG.match(text)
    if m:
        s=text[m.end():-len(m[1])-2]
        if s.startswith('\r\n'): s=s[2:]
        elif s.startswith(('\n','\r')): s=s[1:]
        return s.encode('utf-8')
    result=bytearray(); i=1
    escapes={'a':7,'b':8,'f':12,'n':10,'r':13,'t':9,'v':11,'\\':92,'"':34,"'":39}
    while i<len(text)-1:
        c=text[i]; i+=1
        if c!='\\': result.extend(c.encode('utf-8')); continue
        c=text[i]; i+=1
        if c in escapes: result.append(escapes[c])
        elif c.isdigit():
            chars=c
            while i<len(text)-1 and text[i].isdigit() and len(chars)<3: chars+=text[i]; i+=1
            val=int(chars)
            if val>255: raise SyntaxFailure('Byte escape out of range')
            result.append(val)
        elif c=='x': result.append(int(text[i:i+2],16)); i+=2
        elif c=='z':
            while i<len(text)-1 and text[i].isspace(): i+=1
        elif c=='\n': result.append(10)
        elif c=='\r':
            if i<len(text) and text[i]=='\n': i+=1
            result.append(10)
        else: result.extend(c.encode('utf-8'))
    return bytes(result)

def quote(value):
    if isinstance(value,str): value=value.encode('utf-8')
    parts=[]
    for b in value:
        if b==34: parts.append('\\"')
        elif b==92: parts.append('\\\\')
        elif b==10: parts.append('\\n')
        elif b==13: parts.append('\\r')
        elif b==9: parts.append('\\t')
        elif 32<=b<127: parts.append(chr(b))
        else: parts.append('\\%03d'%b)
    return '"'+''.join(parts)+'"'
