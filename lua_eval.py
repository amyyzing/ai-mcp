"""Bounded, host-isolated evaluator for closed Lua computations.

This is NOT Roblox emulation. Unknown globals, native capabilities and unknown
control flow stop specialization. Only print/warn are recorded (never executed).
Every returned application view is scoped to the reported model, not equivalence
for arbitrary Roblox/executor environments. No eval, exec or host source execution.
"""
from __future__ import annotations
import math, random, re, time
from dataclasses import dataclass
from lua_tokens import quote

class Halt(BaseException): pass
class LuaError(Exception):
    def __init__(self,message,payload=None):
        super().__init__(message);self.payload=payload
class Returned(BaseException):
    def __init__(self,values): self.values=values
class Break(BaseException): pass
class Continue(BaseException): pass
class Multi(list): pass

class Table:
    def __init__(self): self.data={};self.meta=None
    def raw(self,key): return self.data.get((type(key) if isinstance(key,bool) else None,key))
    def put(self,key,value):
        if key is None or isinstance(key,float) and math.isnan(key):raise LuaError('table index is nil or NaN')
        key=(type(key) if isinstance(key,bool) else None,key)
        if value is None: self.data.pop(key,None)
        else: self.data[key]=value
    def keys(self): return [k for _,k in self.data]
    def length(self):
        i=0
        while self.raw(i+1) is not None: i+=1
        return i

class Scope:
    def __init__(self,parent=None,global_table=None):
        self.parent=parent;self.local={};self.global_table=global_table if global_table is not None else parent.global_table
    def find(self,name):
        e=self
        while e:
            if name in e.local:return e
            e=e.parent
        return None

@dataclass(eq=False)
class Closure:
    ast: dict
    scope: Scope

@dataclass(eq=False)
class Native:
    name: str
    function: object

class Evaluator:
    def __init__(self, *, seed=1729, max_steps=1500000, seconds=20):
        self.steps=0;self.max_steps=max_steps;self.deadline=time.monotonic()+seconds
        self.rng=random.Random(seed);self.seed=seed;self.calls=[];self.executed=set();self.decoder_values={}
        self.globals=Table();self.known=set();self.unknown_reads=set();self.active=[];self.random_calls=0;self.sequence=0;self.closures=[]
        self.scope=Scope(global_table=self.globals);self.scaffold={};self.bootstrap_changes=[];self.allowed_absent=set();self.assumed_absent=set()
        self.setup()
    def tick(self,n=None):
        self.steps+=1
        if n:self.executed.add((n['a'],n['b']))
        if self.steps>self.max_steps:raise Halt('Specialization instruction budget reached')
        if self.steps%1024==0 and time.monotonic()>self.deadline:raise Halt('Specialization deadline reached')
    @staticmethod
    def truth(x):return x is not None and x is not False
    @staticmethod
    def first(x):return x[0] if isinstance(x,Multi) and x else None if isinstance(x,Multi) else x
    def numeric(self,x):
        if isinstance(x,bool) or x is None:raise LuaError('attempt to perform arithmetic on a non-number value')
        if isinstance(x,(int,float)):return float(x)
        if isinstance(x,bytes):
            try:return float(x)
            except ValueError:pass
        raise LuaError('attempt to perform arithmetic on a non-number value')
    def tostring(self,v):
        if isinstance(v,bytes):return v
        if v is None:return b'nil'
        if v is True:return b'true'
        if v is False:return b'false'
        if isinstance(v,(float,int)):
            if math.isfinite(v) and v==int(v):return str(int(v)).encode()
            return format(v,'.14g').encode()
        if isinstance(v,Table):
            fn=v.meta.raw(b'__tostring') if v.meta else None
            if fn:return self.first(self.call(fn,[v]))
            raise Halt('Object identity converted to a string; not a closed scalar computation')
        raise Halt('Function/userdata identity converted to string')
    def get(self,obj,key,raw=False):
        if isinstance(obj,bytes):return self.globals.raw(b'string').raw(key)
        if not isinstance(obj,Table): raise LuaError('attempt to index a non-table value')
        result=obj.raw(key)
        if result is not None:return result
        if obj is self.globals and key not in self.known:
            if key in self.allowed_absent:
                self.assumed_absent.add(key);return None
            self.unknown_reads.add(self.tostring(key).decode('utf8','replace'))
            raise Halt('Unmodelled global: '+self.tostring(key).decode('utf8','replace'))
        if obj.meta and not raw:
            index=obj.meta.raw(b'__index')
            if isinstance(index,Table):return self.get(index,key)
            if index is not None:return self.first(self.call(index,[obj,key]))
        return None
    def set(self,obj,key,value,raw=False):
        if not isinstance(obj,Table):raise LuaError('attempt to index a non-table value')
        if obj.meta and not raw and obj.raw(key) is None:
            index=obj.meta.raw(b'__newindex')
            if isinstance(index,Table):return self.set(index,key,value)
            if index is not None:self.call(index,[obj,key,value]);return
        if obj is self.globals:self.known.add(key)
        obj.put(key,value)
    def lookup(self,env,name):
        e=env.find(name)
        return e.local[name] if e else self.get(env.global_table,name.encode())
    def values(self,nodes,env):
        out=[]
        for i,n in enumerate(nodes):
            v=self.eval(n,env)
            out.extend(v if i==len(nodes)-1 and isinstance(v,Multi) else [self.first(v)])
        return out
    def eval(self,n,e):
        self.tick(n);k=n['k']
        if k in ('num','str','literal'):return n['value']
        if k=='name':return self.lookup(e,n['name'])
        if k=='group':return self.first(self.eval(n['value'],e))
        if k=='vararg':return Multi(self.lookup(e,'...'))
        if k=='function':
            fn=Closure(n,e);self.closures.append(fn);return fn
        if k=='table':
            t=Table();idx=1
            for i,(key,val) in enumerate(n['fields']):
                v=self.eval(val,e)
                if key is None:
                    vals=v if i==len(n['fields'])-1 and isinstance(v,Multi) else [self.first(v)]
                    for a in vals:t.put(idx,a);idx+=1
                else:t.put(self.first(self.eval(key,e)),self.first(v))
            return t
        if k=='index':return self.get(self.first(self.eval(n['base'],e)),self.first(self.eval(n['key'],e)))
        if k in ('call','method'):
            if k=='method':
                base=self.first(self.eval(n['base'],e));fn=self.get(base,n['name'].encode());args=[base]+self.values(n['args'],e)
            else:fn=self.first(self.eval(n['func'],e));args=self.values(n['args'],e)
            result=self.call(fn,args)
            # Observe pure first-layer accessor values, never feed them back as assumptions.
            if isinstance(fn,Closure) and len(fn.ast['body'])==1 and fn.ast['body'][0]['k']=='return' and len(result)==1 and isinstance(result[0],bytes):
                key=(n['a'],n['b']);prev=self.decoder_values.setdefault(key,set());prev.add(result[0])
            return result
        if k=='unary':
            v=self.first(self.eval(n['value'],e));op=n['op']
            if op=='not':return not self.truth(v)
            if op=='-':return -self.numeric(v)
            if isinstance(v,bytes):return float(len(v))
            if isinstance(v,Table):
                fn=v.meta.raw(b'__len') if v.meta else None
                return self.first(self.call(fn,[v])) if fn else float(v.length())
            raise LuaError('attempt to get length of a non-table value')
        if k=='binary':
            a=self.first(self.eval(n['left'],e));op=n['op']
            if op=='and':return self.first(self.eval(n['right'],e)) if self.truth(a) else a
            if op=='or':return a if self.truth(a) else self.first(self.eval(n['right'],e))
            b=self.first(self.eval(n['right'],e));return self.binary(op,a,b)
        raise Halt('Unsupported expression: '+k)
    def binary(self,op,a,b):
        if op in ('==','~='):
            equal=(type(a) is type(b) or isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool)) and a==b
            return equal if op=='==' else not equal
        if op in ('<','>','<=','>='):
            if not (isinstance(a,bytes) and isinstance(b,bytes)):
                a=self.numeric(a);b=self.numeric(b)
            return {'<':lambda:a<b,'>':lambda:a>b,'<=':lambda:a<=b,'>=':lambda:a>=b}[op]()
        if op=='..':
            if not isinstance(a,(bytes,int,float)) or not isinstance(b,(bytes,int,float)):raise LuaError('attempt to concatenate a non-string')
            out=self.tostring(a)+self.tostring(b)
            if len(out)>8*1024*1024:raise Halt('String size budget exceeded')
            return out
        a=self.numeric(a);b=self.numeric(b)
        try:
            if op=='+':return a+b
            if op=='-':return a-b
            if op=='*':return a*b
            if op=='/':return a/b if b else math.nan if a==0 else math.copysign(math.inf,a*b)
            if op=='%':return a%b if b else math.nan
            if op=='//':return float(math.floor(a/b))
            if op=='^':return math.pow(a,b)
        except (ValueError,OverflowError,ZeroDivisionError):raise LuaError('numeric domain error')
        raise Halt('Unsupported operator '+op)
    def call(self,fn,args):
        self.tick()
        if isinstance(fn,Table):
            method=fn.meta.raw(b'__call') if fn.meta else None
            if method is None:raise LuaError('attempt to call a table value')
            return self.call(method,[fn]+args)
        if isinstance(fn,Native):
            try:r=fn.function(*args)
            except LuaError:raise
            except (TypeError,ValueError,IndexError,KeyError,OverflowError,ZeroDivisionError) as exc:raise LuaError(str(exc)) from exc
            return r if isinstance(r,Multi) else Multi([r])
        if not isinstance(fn,Closure):raise LuaError('attempt to call a non-function value')
        if len(self.active)>90:raise Halt('Call-depth budget exceeded')
        env=Scope(fn.scope);nfixed=len([p for p in fn.ast['params'] if p!='...'])
        for i,p in enumerate(fn.ast['params']):env.local[p]=args[nfixed:] if p=='...' else (args[i] if i<len(args) else None)
        self.active.append(fn)
        try:self.block(fn.ast['body'],env,new=False)
        except Returned as r:return Multi(r.values)
        finally:self.active.pop()
        return Multi()
    def location(self,target,e):
        if target['k']=='name':return ('local',e.find(target['name']),target['name'])
        if target['k']=='index':return ('index',self.first(self.eval(target['base'],e)),self.first(self.eval(target['key'],e)))
        raise Halt('Unsupported assignment target')
    def assign(self,loc,value,e):
        kind,owner,key=loc
        if kind=='local':
            if owner:owner.local[key]=value
            else:self.set(e.global_table,key.encode(),value)
        else:self.set(owner,key,value)
    def block(self,body,env,new=True):
        e=Scope(env) if new else env
        for s in body:
            self.tick(s);k=s['k']
            if k=='local':
                values=self.values(s['values'],e)
                e=Scope(e)
                for i,t in enumerate(s['targets']):e.local[t['name']]=values[i] if i<len(values) else None
            elif k=='localfunction':
                e=Scope(e)
                e.local[s['target']['name']]=None;e.local[s['target']['name']]=Closure(s['value'],e)
            elif k=='assign':
                locs=[self.location(t,e) for t in s['targets']];vals=self.values(s['values'],e)
                for i,loc in enumerate(locs):self.assign(loc,vals[i] if i<len(vals) else None,e)
            elif k=='compound':
                loc=self.location(s['target'],e)
                old=self.lookup(e,loc[2]) if loc[0]=='local' else self.get(loc[1],loc[2]);val=self.first(self.eval(s['value'],e))
                self.assign(loc,self.binary(s['op'],old,val),e)
            elif k=='callstmt':self.eval(s['value'],e)
            elif k=='return':raise Returned(self.values(s['values'],e))
            elif k=='break':raise Break()
            elif k=='continue':raise Continue()
            elif k=='do':self.block(s['body'],e)
            elif k=='if':
                for cond,body in s['branches']:
                    if self.truth(self.first(self.eval(cond,e))):self.block(body,e);break
                else:self.block(s['other'],e)
            elif k in ('while','repeat'):
                while k=='repeat' or self.truth(self.first(self.eval(s['condition'],e))):
                    inner=Scope(e)
                    try:inner=self.block(s['body'],inner,new=False)
                    except Break:break
                    except Continue:pass
                    if k=='repeat' and self.truth(self.first(self.eval(s['condition'],inner))):break
                    self.tick()
            elif k=='fornum':
                vals=self.values(s['values'],e);i,stop=map(self.numeric,vals[:2]);step=self.numeric(vals[2]) if len(vals)>2 else 1.
                if step==0:raise Halt('Zero-step numeric loop')
                while i<=stop if step>0 else i>=stop:
                    inner=Scope(e);inner.local[s['name']]=i
                    try:self.block(s['body'],inner,new=False)
                    except Break:break
                    except Continue:pass
                    i+=step;self.tick()
            elif k=='forin':
                vals=self.values(s['values'],e);vals+= [None]*max(0,3-len(vals));fn,state,control=vals[:3]
                while True:
                    out=self.call(fn,[state,control])
                    if not out or out[0] is None:break
                    control=out[0];inner=Scope(e)
                    for i,name in enumerate(s['names']):inner.local[name]=out[i] if i<len(out) else None
                    try:self.block(s['body'],inner,new=False)
                    except Break:break
                    except Continue:pass
                    self.tick()
            else:raise Halt('Unsupported statement '+k)
        return e
    def native(self,name,fn):return Native(name,fn)
    def setup(self):
        def add(name,fn):self.globals.put(name.encode(),Native(name,fn));self.known.add(name.encode())
        def lib(name,entries):
            t=Table()
            for k,fn in entries.items():t.put(k.encode(),Native(name+'.'+k,fn) if callable(fn) else fn)
            self.globals.put(name.encode(),t);self.known.add(name.encode())
        def record(name,*args):
            if len(self.calls)>4096:raise Halt('Output event budget exceeded')
            texts=[self.tostring(x) for x in args]
            self.calls.append({'function':name,'arguments':args[:],'text':b'\t'.join(texts)})
            return Multi()
        add('print',lambda *a:record('print',*a));add('warn',lambda *a:record('warn',*a))
        add('type',lambda x: b'nil' if x is None else b'boolean' if isinstance(x,bool) else b'number' if isinstance(x,(int,float)) else b'string' if isinstance(x,bytes) else b'function' if isinstance(x,(Closure,Native)) else b'table')
        add('tostring',self.tostring)
        def tonumber(v,base=None):
            try:return float(int(v,int(base))) if base else self.numeric(v)
            except (LuaError,ValueError,TypeError):return None
        add('tonumber',tonumber)
        def select(i,*a):
            if i==b'#':return float(len(a))
            i=int(self.numeric(i));i=len(a)+i+1 if i<0 else i
            if i<1:raise LuaError('index out of range')
            return Multi(a[i-1:])
        add('select',select)
        def error(msg=None,level=1):
            payload=self.tostring(msg) if level==0 else b'protected:1: '+self.tostring(msg)
            raise LuaError(payload.decode('latin1'),payload=payload)
        add('error',error)
        def assertion(v,*a):
            if not self.truth(v):error(a[0] if a else b'assertion failed!')
            return Multi([v,*a])
        add('assert',assertion)
        def pcall(fn,*a):
            try:return Multi([True,*self.call(fn,list(a))])
            except LuaError as ex:return Multi([False,ex.payload if ex.payload is not None else ('protected:1: '+str(ex)).encode('latin1','replace')])
        add('pcall',pcall)
        def xpcall(fn,handler,*a):
            try:return Multi([True,*self.call(fn,list(a))])
            except LuaError as ex:return Multi([False,*self.call(handler,[str(ex).encode()])])
        add('xpcall',xpcall)
        def nxt(t,k=None):
            if not isinstance(t,Table):raise LuaError('table expected')
            keys=t.keys()
            pos=0 if k is None else keys.index(k)+1
            if pos>=len(keys):return Multi([None])
            key=keys[pos];return Multi([key,t.raw(key)])
        add('next',nxt);add('pairs',lambda t:Multi([Native('next',nxt),t,None]))
        def inext(t,k):
            k=self.numeric(k)+1;v=t.raw(k);return Multi([None]) if v is None else Multi([k,v])
        add('ipairs',lambda t:Multi([Native('ipairs-next',inext),t,0.]))
        add('rawget',lambda t,k:self.get(t,k,True))
        add('rawset',lambda t,k,v:(self.set(t,k,v,True),t)[1])
        add('rawequal',lambda a,b:self.binary('==',a,b))
        def setmeta(t,m):
            if not isinstance(t,Table) or m is not None and not isinstance(m,Table):raise LuaError('table expected')
            t.meta=m;return t
        add('setmetatable',setmeta)
        add('getmetatable',lambda t:t.meta.raw(b'__metatable') if isinstance(t,Table) and t.meta and t.meta.raw(b'__metatable') is not None else t.meta if isinstance(t,Table) else None)
        add('getfenv',lambda *_:self.globals)
        def unpack(t,i=1,j=None):
            end=t.length() if j is None else int(j)
            if end-int(i)>100000:raise Halt('Unpack budget exceeded')
            return Multi(t.raw(k) for k in range(int(i),end+1))
        add('unpack',unpack)
        def pack(*a):
            t=Table()
            for i,v in enumerate(a,1):t.put(i,v)
            t.put(b'n',float(len(a)));return t
        def insert(t,*a):
            if not isinstance(t,Table):raise LuaError('table expected')
            if t.length()>100000:raise Halt('Table budget exceeded')
            if len(a)==1:pos=t.length()+1;v=a[0]
            elif len(a)==2:pos=int(a[0]);v=a[1]
            else:raise LuaError('wrong number of arguments to insert')
            for i in range(t.length(),pos-1,-1):t.put(i+1,t.raw(i))
            t.put(pos,v);return Multi()
        def remove(t,pos=None):
            pos=t.length() if pos is None else int(pos);v=t.raw(pos)
            for i in range(pos,t.length()):t.put(i,t.raw(i+1))
            t.put(t.length(),None);return v
        def concat(t,sep=b'',i=1,j=None):
            end=t.length() if j is None else int(j)
            if end-int(i)>100000:raise Halt('Concat budget exceeded')
            result=sep.join(self.tostring(t.raw(k)) for k in range(int(i),end+1))
            if len(result)>8*1024**2:raise Halt('String budget exceeded')
            return result
        lib('table',{'insert':insert,'remove':remove,'concat':concat,'unpack':unpack,'pack':pack})
        def substring(s,i,j=None):
            if not isinstance(s,bytes):s=self.tostring(s)
            i=int(i);j=len(s) if j is None else int(j);i=len(s)+i+1 if i<0 else i;j=len(s)+j+1 if j<0 else j
            return s[max(i-1,0):max(0,j)]
        def char(*a):
            values=[]
            for v in a:
                v=self.numeric(v)
                if not v.is_integer() or not 0<=v<=255:raise LuaError('invalid char')
                values.append(int(v))
            return bytes(values)
        def byte(s,i=1,j=None):return Multi(float(b) for b in substring(s,i,i if j is None else j))
        def pattern(p):
            s=p.decode('latin1');out='';i=0
            while i<len(s):
                c=s[i];i+=1
                if c=='%':
                    if i>=len(s):raise LuaError('malformed pattern')
                    q=s[i];i+=1
                    cls={'d':r'\d','a':'[A-Za-z]','w':'[A-Za-z0-9]','s':r'\s','x':'[0-9A-Fa-f]','p':r'[^\w\s]','c':'[\x00-\x1f\x7f]','z':'\x00'}
                    if q in ('b','f'):raise Halt('Unsupported Lua pattern construct')
                    out+=cls.get(q,re.escape(q))
                elif c=='-':out+='*?'
                elif c in '{}|\\':out+=re.escape(c)
                else:out+=c
            return out
        def match(s,p,i=1):
            # Bound input and pattern; never execute a user-supplied regex extension.
            if len(s)>65536 or len(p)>1024:raise Halt('Pattern budget exceeded')
            r=re.search(pattern(p),substring(s,i).decode('latin1'))
            if not r:return Multi([None])
            return Multi(x.encode('latin1') if x is not None else None for x in (r.groups() or (r.group(0),)))
        def gmatch(s,p):
            if len(s)>65536 or len(p)>1024:raise Halt('Pattern budget exceeded')
            matches=iter(re.finditer(pattern(p),s.decode('latin1')))
            def nextmatch(*_):
                r=next(matches,None)
                return Multi([None]) if r is None else Multi(x.encode('latin1') for x in (r.groups() or (r.group(0),)))
            return Native('gmatch-next',nextmatch)
        def find(s,p,i=1,plain=False):
            sub=substring(s,i);offset=len(s)-len(sub)
            if plain:
                ix=sub.find(p);return Multi([None]) if ix<0 else Multi([float(ix+offset+1),float(ix+offset+len(p))])
            r=re.search(pattern(p),sub.decode('latin1'))
            if not r:return Multi([None])
            return Multi([float(r.start()+offset+1),float(r.end()+offset),*[x.encode('latin1') for x in r.groups()]])
        def repeat(s,n,sep=b''):
            n=int(n)
            if n<0:n=0
            if n*(len(s)+len(sep))>8*1024**2:raise Halt('String budget exceeded')
            return sep.join([s]*n)
        def gsub(s,p,replacement,n=None):
            if len(s)>65536 or len(p)>1024:raise Halt('Pattern budget exceeded')
            count=0
            def sub(m):
                nonlocal count
                count+=1
                if isinstance(replacement,bytes):
                    text=replacement.decode('latin1')
                    def expand(mt):
                        k=mt.group(1)
                        return '%' if k=='%' else m.group(int(k)) or ''
                    return re.sub(r'%(\d|%)',expand,text)
                args=[x.encode('latin1') for x in (m.groups() or (m.group(0),))]
                value=self.get(replacement,args[0]) if isinstance(replacement,Table) else self.first(self.call(replacement,args))
                return m.group(0) if value is None or value is False else self.tostring(value).decode('latin1')
            result=re.sub(pattern(p),sub,s.decode('latin1'),count=0 if n is None else int(n))
            return Multi([result.encode('latin1'),float(count)])
        lib('string',{'len':lambda s:float(len(s)),'char':char,'byte':byte,'sub':substring,'reverse':lambda s:s[::-1],'lower':lambda s:s.lower(),'upper':lambda s:s.upper(),'rep':repeat,'match':match,'find':find,'gmatch':gmatch,'gsub':gsub})
        def rand(a=None,b=None):
            self.random_calls+=1
            if a is None:return self.rng.random()
            if b is None:a,b=1,a
            return float(self.rng.randint(int(a),int(b)))
        lib('math',{'floor':lambda x:float(math.floor(x)),'ceil':lambda x:float(math.ceil(x)),'abs':abs,'sqrt':math.sqrt,'sin':math.sin,'cos':math.cos,'tan':math.tan,'log':math.log,'exp':math.exp,'min':min,'max':max,'pow':math.pow,'fmod':math.fmod,'random':rand,'pi':math.pi,'huge':math.inf,'ldexp':math.ldexp})
        self.known.update([b'debug',b'newproxy',b'_VERSION'])
        self.globals.put(b'_VERSION',b'Luau')
        self.known.update([b'_G',b'_ENV']);self.globals.put(b'_G',self.globals);self.globals.put(b'_ENV',self.globals)
    def run(self,body):
        self.scope.local['...']=[]
        try:self.block(body,self.scope,new=False);return Multi()
        except Returned as r:return Multi(r.values)
