"""Analysis-source renderer. Rewrites only closed literal arithmetic expressions.

Formatting can affect anti-beautify diagnostics; this artifact is an analysis
view, not an assertion of executable equivalence in every debug environment.
"""
import math
from lua_tokens import quote
from lua_eval import Evaluator,LuaError
from lua_parse import walk

MISSING=object()
def literal(v):
    if v is None:return 'nil'
    if v is True:return 'true'
    if v is False:return 'false'
    if isinstance(v,(str,bytes)):return quote(v)
    if isinstance(v,(int,float)):
        if math.isnan(v):return '(0/0)'
        if math.isinf(v):return '(1/0)' if v>0 else '(-1/0)'
        if v==0 and math.copysign(1,v)<0:return '-0.0'
        return str(int(v)) if v==int(v) else repr(v)
    raise ValueError('Non-scalar cannot be emitted as a literal')

def constant(n):
    k=n['k']
    if k in ('num','str','literal'):return n['value']
    if k=='group':return constant(n['value'])
    if k=='unary':
        v=constant(n['value'])
        if v is MISSING:return MISSING
        if n['op']=='not':return not Evaluator.truth(v)
        if n['op']=='-' and isinstance(v,(int,float)) and not isinstance(v,bool):return -v
        if n['op']=='#' and isinstance(v,bytes):return float(len(v))
    if k=='binary':
        a=constant(n['left']);b=constant(n['right']);op=n['op']
        if a is MISSING:return MISSING
        if op=='and':return b if Evaluator.truth(a) else a
        if op=='or':return a if Evaluator.truth(a) else b
        if b is MISSING:return MISSING
        # Only numeric operations; do not approximate metamethods or tostring.
        if isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool):
            try:
                if op=='+':v=a+b
                elif op=='-':v=a-b
                elif op=='*':v=a*b
                elif op=='/':v=a/b
                elif op=='%':v=a%b
                elif op=='^':v=math.pow(a,b)
                elif op=='//':v=float(math.floor(a/b))
                elif op=='==':return a==b
                elif op=='~=':return a!=b
                elif op=='<':return a<b
                elif op=='>':return a>b
                elif op=='<=':return a<=b
                elif op=='>=':return a>=b
                else:return MISSING
                return v if math.isfinite(v) else MISSING
            except (ArithmeticError,ValueError):pass
        if op=='..' and isinstance(a,bytes) and isinstance(b,bytes):return a+b
    return MISSING

class Emitter:
    def __init__(self,replacements=None):self.replacements=replacements or {};self.folds=0
    def expr(self,n,depth=0):
        k=n['k'];v=constant(n)
        if id(n) in self.replacements:return literal(self.replacements[id(n)])
        if v is not MISSING:
            if k not in ('num','str','literal'):self.folds+=1
            return literal(v)
        if k=='name':return n['name']
        if k=='vararg':return '...'
        if k=='group':return '('+self.expr(n['value'],depth)+')'
        if k=='unary':return '('+n['op']+' '+self.expr(n['value'],depth)+')'
        if k=='binary':return '('+self.expr(n['left'],depth)+' '+n['op']+' '+self.expr(n['right'],depth)+')'
        if k=='index':return '('+self.expr(n['base'],depth)+')['+self.expr(n['key'],depth)+']'
        if k=='call':return '('+self.expr(n['func'],depth)+')('+', '.join(self.expr(x,depth) for x in n['args'])+')'
        if k=='method':return '('+self.expr(n['base'],depth)+'):'+n['name']+'('+', '.join(self.expr(x,depth) for x in n['args'])+')'
        if k=='table':return '{'+', '.join(('['+self.expr(key,depth)+'] = ' if key is not None else '')+self.expr(val,depth) for key,val in n['fields'])+'}'
        if k=='function':return 'function('+', '.join(n['params'])+')\n'+self.block(n['body'],depth+1)+'\n'+'    '*depth+'end'
        raise ValueError('Cannot emit '+k)
    def block(self,body,depth=0):
        out=[];ind='    '*depth
        for s in body:
            k=s['k'];ex=lambda n:self.expr(n,depth);multi=lambda a:', '.join(ex(v) for v in a)
            if k=='local':text='local '+multi(s['targets'])+(' = '+multi(s['values']) if s['values'] else '')
            elif k=='localfunction':text='local function '+s['target']['name']+'('+', '.join(s['value']['params'])+')\n'+self.block(s['value']['body'],depth+1)+'\n'+ind+'end'
            elif k=='assign':text=multi(s['targets'])+' = '+multi(s['values'])
            elif k=='compound':text=ex(s['target'])+' '+s['op']+'= '+ex(s['value'])
            elif k=='return':text='return'+(' '+multi(s['values']) if s['values'] else '')
            elif k in ('break','continue'):text=k
            elif k=='callstmt':text=ex(s['value'])
            elif k=='do':text='do\n'+self.block(s['body'],depth+1)+'\n'+ind+'end'
            elif k=='while':text='while '+ex(s['condition'])+' do\n'+self.block(s['body'],depth+1)+'\n'+ind+'end'
            elif k=='repeat':text='repeat\n'+self.block(s['body'],depth+1)+'\n'+ind+'until '+ex(s['condition'])
            elif k=='fornum':text='for '+s['name']+' = '+multi(s['values'])+' do\n'+self.block(s['body'],depth+1)+'\n'+ind+'end'
            elif k=='forin':text='for '+', '.join(s['names'])+' in '+multi(s['values'])+' do\n'+self.block(s['body'],depth+1)+'\n'+ind+'end'
            elif k=='if':
                parts=[]
                for i,(cond,b) in enumerate(s['branches']):parts.append(('if ' if i==0 else ind+'elseif ')+ex(cond)+' then\n'+self.block(b,depth+1))
                if s['other']:parts.append(ind+'else\n'+self.block(s['other'],depth+1))
                parts.append(ind+'end');text='\n'.join(parts)
            else:raise ValueError('Cannot emit statement '+k)
            # Semicolons avoid Lua's ambiguous parenthesized call continuation.
            out.append(ind+text+(';' if k in ('local','localfunction','assign','compound','callstmt','do','if','while','fornum','forin','repeat') else ''))
        return '\n'.join(out)
