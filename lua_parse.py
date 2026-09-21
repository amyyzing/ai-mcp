"""Bounded Lua/Luau expression parser used by the local recovery adapter.

It deliberately rejects unsupported syntax instead of guessing transformations.
AST nodes retain character spans in the submitted source.
"""
from lua_tokens import lex, number, decode_string, SyntaxFailure

BINARY={'or':1,'and':2,'<':3,'>':3,'<=':3,'>=':3,'~=':3,'==':3,'..':4,'+':5,'-':5,'*':6,'/':6,'%':6,'//':6,'^':8}
RIGHT={'..','^'}

def node(kind,a,b,**kw): return dict(k=kind,a=a,b=b,**kw)

class Parser:
    def __init__(self, source, maximum=500000):
        self.source=source; self.tokens=lex(source); self.i=0; self.depth=0
        if len(self.tokens)>maximum: raise SyntaxFailure('Parser token budget exceeded')
    def peek(self): return self.tokens[self.i].text
    def take(self, text=None):
        t=self.tokens[self.i]
        if text is not None and t.text!=text: raise SyntaxFailure(f'Expected {text!r} at {t.start}, got {t.text!r}')
        self.i+=1; return t
    def accept(self,text):
        if self.peek()==text: self.take(); return True
        return False
    def name(self):
        t=self.take()
        if t.kind!='name': raise SyntaxFailure('Expected identifier')
        return node('name',t.start,t.end,name=t.text)
    def block(self, stops=('end','else','elseif','until','<eof>')):
        out=[]
        while self.peek() not in stops:
            if self.accept(';'): continue
            out.append(self.statement()); self.accept(';')
        return out
    def exprs(self):
        out=[self.expr()]
        while self.accept(','): out.append(self.expr())
        return out
    def function(self,start):
        self.take('('); params=[]
        if self.peek()!=')':
            while True:
                if self.peek()=='...': params.append('...');self.take()
                else: params.append(self.name()['name'])
                if not self.accept(','): break
        self.take(')'); body=self.block(); end=self.take('end').end
        return node('function',start,end,params=params,body=body)
    def statement(self):
        t=self.tokens[self.i]; start=t.start
        if self.accept('local'):
            if self.accept('function'):
                target=self.name(); fn=self.function(start)
                return node('localfunction',start,fn['b'],target=target,value=fn)
            names=[self.name()]
            while self.accept(','): names.append(self.name())
            values=self.exprs() if self.accept('=') else []
            return node('local',start,self.tokens[self.i-1].end,targets=names,values=values)
        if self.accept('function'):
            target=self.name(); method=False
            while self.peek() in ('.',':'):
                op=self.take().text; member=self.name(); method=op==':'
                target=node('index',start,member['b'],base=target,key=node('str',member['a'],member['b'],value=member['name'].encode()))
            fn=self.function(start)
            if method: fn['params'].insert(0,'self')
            return node('assign',start,fn['b'],targets=[target],values=[fn])
        if self.accept('return'):
            values=[] if self.peek() in ('end','else','elseif','until','<eof>',';') else self.exprs()
            return node('return',start,self.tokens[self.i-1].end,values=values)
        if self.peek() in ('break','continue'):
            return node(self.take().text,start,self.tokens[self.i-1].end)
        if self.accept('do'):
            body=self.block(); end=self.take('end').end; return node('do',start,end,body=body)
        if self.accept('while'):
            cond=self.expr(); self.take('do'); body=self.block(); end=self.take('end').end
            return node('while',start,end,condition=cond,body=body)
        if self.accept('repeat'):
            body=self.block(); self.take('until'); cond=self.expr()
            return node('repeat',start,cond['b'],condition=cond,body=body)
        if self.accept('if'):
            branches=[]
            while True:
                cond=self.expr(); self.take('then'); body=self.block(); branches.append((cond,body))
                if not self.accept('elseif'): break
            other=self.block() if self.accept('else') else []
            end=self.take('end').end; return node('if',start,end,branches=branches,other=other)
        if self.accept('for'):
            names=[self.name()]
            if self.accept('='):
                values=self.exprs()
                if len(values) not in (2,3): raise SyntaxFailure('Invalid numeric for')
                self.take('do'); body=self.block(); end=self.take('end').end
                return node('fornum',start,end,name=names[0]['name'],values=values,body=body)
            while self.accept(','): names.append(self.name())
            self.take('in'); values=self.exprs();self.take('do');body=self.block();end=self.take('end').end
            return node('forin',start,end,names=[v['name'] for v in names],values=values,body=body)
        first=self.expr()
        if self.peek() in ('=',','):
            targets=[first]
            while self.accept(','): targets.append(self.expr())
            self.take('=');values=self.exprs()
            if any(v['k'] not in ('name','index') for v in targets): raise SyntaxFailure('Invalid assignment target')
            return node('assign',start,values[-1]['b'],targets=targets,values=values)
        if self.peek() in ('+=','-=','*=','/=','%=','^=','..=','//='):
            op=self.take().text[:-1]; value=self.expr()
            return node('compound',start,value['b'],target=first,op=op,value=value)
        if first['k'] not in ('call','method'): raise SyntaxFailure(f'Invalid statement at {start}')
        return node('callstmt',start,first['b'],value=first)
    def expr(self,minimum=0):
        self.depth+=1
        if self.depth>180: raise SyntaxFailure('Expression nesting budget exceeded')
        try:
            t=self.take(); start=t.start
            if t.text in ('not','-','#'):
                operand=self.expr(7); left=node('unary',start,operand['b'],op=t.text,value=operand)
            elif t.kind=='num': left=node('num',start,t.end,value=number(t.text))
            elif t.kind=='str': left=node('str',start,t.end,value=decode_string(t.text))
            elif t.text in ('nil','true','false'):
                left=node('literal',start,t.end,value={'nil':None,'true':True,'false':False}[t.text])
            elif t.text=='...': left=node('vararg',start,t.end)
            elif t.text=='function': left=self.function(start)
            elif t.text=='(':
                e=self.expr(); end=self.take(')').end; left=node('group',start,end,value=e)
            elif t.text=='{':
                fields=[]
                while self.peek()!='}':
                    if self.accept('['):
                        key=self.expr(); self.take(']');self.take('='); val=self.expr()
                    elif self.tokens[self.i].kind=='name' and self.tokens[self.i+1].text=='=':
                        key=self.name();key=node('str',key['a'],key['b'],value=key['name'].encode());self.take('=');val=self.expr()
                    else: key=None;val=self.expr()
                    fields.append((key,val))
                    if not self.accept(',') and not self.accept(';'): break
                left=node('table',start,self.take('}').end,fields=fields)
            elif t.kind=='name': left=node('name',start,t.end,name=t.text)
            else: raise SyntaxFailure(f'Unsupported expression {t.text!r} at {start}')
            while True:
                op=self.peek()
                if op=='[':
                    self.take(); key=self.expr();end=self.take(']').end
                    left=node('index',start,end,base=left,key=key)
                elif op=='.':
                    self.take();key=self.name();left=node('index',start,key['b'],base=left,key=node('str',key['a'],key['b'],value=key['name'].encode()))
                elif op==':':
                    self.take();name=self.name()['name'];args=self.args()
                    left=node('method',start,self.tokens[self.i-1].end,base=left,name=name,args=args)
                elif op in ('(','{') or self.tokens[self.i].kind=='str':
                    args=self.args();left=node('call',start,self.tokens[self.i-1].end,func=left,args=args)
                elif op in BINARY and BINARY[op]>minimum:
                    self.take(); prec=BINARY[op];right=self.expr(prec-1 if op in RIGHT else prec)
                    left=node('binary',start,right['b'],left=left,right=right,op=op)
                else: break
            return left
        finally: self.depth-=1
    def args(self):
        if self.accept('('):
            args=[] if self.peek()==')' else self.exprs(); self.take(')');return args
        if self.peek()=='{': return [self.expr(9)]
        t=self.take()
        if t.kind=='str': return [node('str',t.start,t.end,value=decode_string(t.text))]
        raise SyntaxFailure('Expected call arguments')
    def parse(self):
        body=self.block();self.take('<eof>');return body

def walk(value):
    if isinstance(value,dict) and 'k' in value:
        yield value
        for key,v in value.items():
            if key not in ('a','b','k','value') or isinstance(v,(list,dict,tuple)): yield from walk(v)
    elif isinstance(value,(list,tuple)):
        for v in value: yield from walk(v)
