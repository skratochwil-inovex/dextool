/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.
*/
module dextool.plugin.mutate.backend.analyze.pass_clang;

import logger = std.experimental.logger;
import std.algorithm : among, map, sort, filter;
import std.array : empty, array;
import std.exception : collectException;
import std.format : formattedWrite;
import std.meta : AliasSeq;
import std.typecons : Nullable, scoped;

import automem : vector, Vector;

import clang.Cursor : Cursor;
import clang.Eval : Eval;
import clang.Type : Type;
import clang.c.Index : CXTypeKind, CXCursorKind, CXEvalResultKind, CXTokenKind;

import cpptooling.analyzer.clang.cursor_logger : logNode, mixinNodeLog;

import dextool.clang_extensions : getUnderlyingExprNode;

import dextool.type : Path;

import dextool.plugin.mutate.backend.analyze.ast : Interval, Location;
import dextool.plugin.mutate.backend.analyze.extensions;
import dextool.plugin.mutate.backend.analyze.utility;
import dextool.plugin.mutate.backend.type : Language, SourceLoc, Offset, SourceLocRange;

import analyze = dextool.plugin.mutate.backend.analyze.ast;

alias accept = dextool.plugin.mutate.backend.analyze.extensions.accept;

/** Translate a clang AST to a mutation AST.
 */
analyze.Ast toMutateAst(const Cursor root) @trusted {
    import cpptooling.analyzer.clang.ast : ClangAST;

    auto svisitor = scoped!BaseVisitor();
    auto visitor = cast(BaseVisitor) svisitor;
    auto ast = ClangAST!BaseVisitor(root);
    ast.accept(visitor);
    return visitor.ast;
}

private:

struct OperatorCursor {
    analyze.Expr astOp;

    // the whole expression
    analyze.Location exprLoc;
    DeriveCursorTypeResult exprTy;

    // the operator itself
    analyze.Operator operator;
    analyze.Location opLoc;

    Cursor lhs;
    Cursor rhs;

    /// Add the result to the AST and astOp to the parent.
    /// astOp is set to have two children, lhs and rhs.
    void put(analyze.Node parent, ref analyze.Ast ast) @safe {
        ast.put(astOp, exprLoc);
        ast.put(operator, opLoc);

        exprTy.put(ast);

        if (exprTy.type !is null)
            ast.put(astOp, exprTy.id);

        if (exprTy.symbol !is null)
            ast.put(astOp, exprTy.symId);

        parent.children ~= astOp;
    }
}

Nullable!OperatorCursor operatorCursor(T)(T node) {
    import dextool.clang_extensions : getExprOperator, OpKind, ValueKind, getUnderlyingExprNode;

    auto op = getExprOperator(node.cursor);
    if (!op.isValid)
        return typeof(return)();

    auto path = op.cursor.location.path.Path;
    if (path.empty)
        return typeof(return)();

    OperatorCursor res;

    void sidesPoint() {
        auto sides = op.sides;
        if (sides.lhs.isValid) {
            res.lhs = getUnderlyingExprNode(sides.lhs);
        }
        if (sides.rhs.isValid) {
            res.rhs = getUnderlyingExprNode(sides.rhs);
        }
    }

    // the operator itself
    void opPoint() {
        auto loc = op.location;
        auto sr = loc.spelling;
        res.operator = new analyze.Operator;
        res.opLoc = new analyze.Location(path, Interval(sr.offset,
                cast(uint)(sr.offset + op.length)), SourceLocRange(SourceLoc(loc.line,
                loc.column), SourceLoc(loc.line, cast(uint)(loc.column + op.length))));
    }

    // the arguments and the operator
    void exprPoint() {
        auto sr = op.cursor.extent;
        res.exprLoc = new analyze.Location(path, Interval(sr.start.offset,
                sr.end.offset), SourceLocRange(SourceLoc(sr.start.line,
                sr.start.column), SourceLoc(sr.end.line, sr.end.column)));
        res.exprTy = deriveCursorType(op.cursor);
        switch (op.kind) with (OpKind) {
        case OO_Star: // "*"
            goto case;
        case Mul: // "*"
            res.astOp = new analyze.OpMul;
            break;
        case OO_Slash: // "/"
            goto case;
        case Div: // "/"
            res.astOp = new analyze.OpDiv;
            break;
        case OO_Percent: // "%"
            goto case;
        case Rem: // "%"
            res.astOp = new analyze.OpMod;
            break;
        case OO_Plus: // "+"
            goto case;
        case Add: // "+"
            res.astOp = new analyze.OpAdd;
            break;
        case OO_Minus: // "-"
            goto case;
        case Sub: // "-"
            res.astOp = new analyze.OpSub;
            break;
        case OO_Less: // "<"
            goto case;
        case LT: // "<"
            res.astOp = new analyze.OpLess;
            break;
        case OO_Greater: // ">"
            goto case;
        case GT: // ">"
            res.astOp = new analyze.OpGreater;
            break;
        case OO_LessEqual: // "<="
            goto case;
        case LE: // "<="
            res.astOp = new analyze.OpLessEq;
            break;
        case OO_GreaterEqual: // ">="
            goto case;
        case GE: // ">="
            res.astOp = new analyze.OpGreaterEq;
            break;
        case OO_EqualEqual: // "=="
            goto case;
        case EQ: // "=="
            res.astOp = new analyze.OpEqual;
            break;
        case OO_Exclaim: // "!"
            goto case;
        case LNot: // "!"
            res.astOp = new analyze.OpNegate;
            break;
        case OO_ExclaimEqual: // "!="
            goto case;
        case NE: // "!="
            res.astOp = new analyze.OpNotEqual;
            break;
        case OO_AmpAmp: // "&&"
            goto case;
        case LAnd: // "&&"
            res.astOp = new analyze.OpAnd;
            break;
        case OO_PipePipe: // "||"
            goto case;
        case LOr: // "||"
            res.astOp = new analyze.OpOr;
            break;
        case OO_Amp: // "&"
            goto case;
        case And: // "&"
            res.astOp = new analyze.OpAndBitwise;
            break;
        case OO_Pipe: // "|"
            goto case;
        case Or: // "|"
            res.astOp = new analyze.OpOrBitwise;
            break;
        case OO_StarEqual: // "*="
            goto case;
        case MulAssign: // "*="
            res.astOp = new analyze.OpAssignMul;
            break;
        case OO_SlashEqual: // "/="
            goto case;
        case DivAssign: // "/="
            res.astOp = new analyze.OpAssignDiv;
            break;
        case OO_PercentEqual: // "%="
            goto case;
        case RemAssign: // "%="
            res.astOp = new analyze.OpAssignMod;
            break;
        case OO_PlusEqual: // "+="
            goto case;
        case AddAssign: // "+="
            res.astOp = new analyze.OpAssignAdd;
            break;
        case OO_MinusEqual: // "-="
            goto case;
        case SubAssign: // "-="
            res.astOp = new analyze.OpAssignSub;
            break;
        case OO_AmpEqual: // "&="
            goto case;
        case AndAssign: // "&="
            res.astOp = new analyze.OpAssignAndBitwise;
            break;
        case OrAssign: // "|="
            goto case;
        case OO_PipeEqual: // "|="
            res.astOp = new analyze.OpAssignOrBitwise;
            break;
        case ShlAssign: // "<<="
            goto case;
        case ShrAssign: // ">>="
            goto case;
        case XorAssign: // "^="
            goto case;
        case OO_CaretEqual: // "^="
            goto case;
        case OO_Equal: // "="
            goto case;
        case Assign: // "="
            res.astOp = new analyze.OpAssign;
            break;
            //case Xor: // "^"
            //case OO_Caret: // "^"
            //case OO_Tilde: // "~"
        default:
            res.astOp = new analyze.BinaryOp;
        }
    }

    exprPoint;
    opPoint;
    sidesPoint;
    return typeof(return)(res);
}

struct CaseStmtCursor {
    analyze.Location branch;
    analyze.Location insideBranch;

    Cursor inner;
}

Nullable!CaseStmtCursor caseStmtCursor(T)(T node) {
    import dextool.clang_extensions : getCaseStmt;

    auto mp = getCaseStmt(node.cursor);
    if (!mp.isValid)
        return typeof(return)();

    auto path = node.cursor.location.path.Path;
    if (path.empty)
        return typeof(return)();

    auto extent = node.cursor.extent;

    CaseStmtCursor res;
    res.inner = mp.subStmt;

    auto sr = res.inner.extent;
    auto insideLoc = SourceLocRange(SourceLoc(sr.start.line, sr.start.column),
            SourceLoc(sr.end.line, sr.end.column));
    auto offs = Interval(sr.start.offset, sr.end.offset);
    if (res.inner.kind == CXCursorKind.caseStmt) {
        auto colon = mp.colonLocation;
        insideLoc.begin = SourceLoc(colon.line, colon.column + 1);
        insideLoc.end = insideLoc.begin;

        // a case statement with fallthrough. the only point to inject a bomb
        // is directly after the semicolon
        offs.begin = colon.offset + 1;
        offs.end = offs.begin;
    } else if (res.inner.kind != CXCursorKind.compoundStmt) {
        offs.end = findTokenOffset(node.cursor.translationUnit.cursor.tokens,
                offs, CXTokenKind.punctuation);
    }

    void subStmt() {
        res.insideBranch = new analyze.Location(path, offs, insideLoc);
    }

    void stmt() {
        auto loc = extent.start;
        auto loc_end = extent.end;
        // reuse the end from offs because it covers either only the
        // fallthrough OR also the end semicolon
        auto stmt_offs = Interval(extent.start.offset, offs.end);
        res.branch = new analyze.Location(path, stmt_offs,
                SourceLocRange(SourceLoc(loc.line, loc.column),
                    SourceLoc(loc_end.line, loc_end.column)));
    }

    stmt;
    subStmt;
    return typeof(return)(res);
}

@safe:

Location toLocation(ref const Cursor c) {
    auto e = c.extent;
    auto interval = Interval(e.start.offset, e.end.offset);
    auto begin = e.start;
    auto end = e.end;
    return new Location(e.path.Path, interval, SourceLocRange(SourceLoc(begin.line,
            begin.column), SourceLoc(end.line, end.column)));
}

/** Find all mutation points that affect a whole expression.
 *
 * TODO change the name of the class. It is more than just an expression
 * visitor.
 *
 * # Usage of kind_stack
 * All usage of the kind_stack shall be documented here.
 *  - track assignments to avoid generating unary insert operators for the LHS.
 */
final class BaseVisitor : ExtendedVisitor {
    import clang.c.Index : CXCursorKind, CXTypeKind;
    import cpptooling.analyzer.clang.ast;
    import dextool.clang_extensions : getExprOperator, OpKind;

    alias visit = ExtendedVisitor.visit;

    // the depth the visitor is at.
    uint indent;
    // A stack of visited cursors up to the current one.
    Stack!(analyze.Node) nstack;

    /// The elements that where removed from the last decrement.
    Vector!(analyze.Node) lastDecr;

    /// List of macro locations which blacklist mutants that would be injected
    /// in any of them.
    BlackList blacklist;

    analyze.Ast ast;

    this() nothrow {
    }

    override void incr() @safe {
        ++indent;
        lastDecr.clear;
    }

    override void decr() @trusted {
        --indent;

        lastDecr = nstack.popUntil(indent);
    }

    private void pushStack(analyze.Node n, analyze.Location l) @trusted {
        n.blacklist = blacklist.inside(l);
        nstack.put(n, indent);
    }

    /// Returns: true if it is OK to modify the cursor
    private void pushStack(AstT, ClangT)(AstT n, ClangT v) @trusted {
        auto loc = v.cursor.toLocation;
        ast.put(n, loc);
        nstack.back.children ~= n;
        pushStack(n, loc);
    }

    override void visit(const(TranslationUnit) v) {
        mixin(mixinNodeLog!());

        blacklist = BlackList(v.cursor);

        ast.root = new analyze.TranslationUnit;
        auto loc = v.cursor.toLocation;
        ast.put(ast.root, loc);
        pushStack(ast.root, loc);

        v.accept(this);
    }

    override void visit(const(Attribute) v) {
        mixin(mixinNodeLog!());
        v.accept(this);
    }

    override void visit(const(Declaration) v) {
        mixin(mixinNodeLog!());
        v.accept(this);
    }

    override void visit(const(Directive) v) {
        mixin(mixinNodeLog!());
        v.accept(this);
    }

    override void visit(const(Reference) v) {
        mixin(mixinNodeLog!());
        v.accept(this);
    }

    override void visit(const(Statement) v) {
        mixin(mixinNodeLog!());
        v.accept(this);
    }

    override void visit(const(Expression) v) {
        import cpptooling.analyzer.clang.ast : dispatch;
        import dextool.clang_extensions : getUnderlyingExprNode;

        mixin(mixinNodeLog!());

        auto ue = Cursor(getUnderlyingExprNode(v.cursor));
        if (ue.isValid && ue != v.cursor) {
            incr;
            scope (exit)
                decr;
            dispatch(ue, this);
        } else {
            pushStack(new analyze.Expr, v);
            v.accept(this);
        }
    }

    override void visit(const(Preprocessor) v) {
        mixin(mixinNodeLog!());

        const bool isCpp = v.spelling == "__cplusplus";

        if (isCpp)
            ast.lang = Language.cpp;
        else if (ast.lang != Language.cpp)
            ast.lang = Language.c;

        v.accept(this);
    }

    override void visit(const(EnumDecl) v) @trusted {
        mixin(mixinNodeLog!());

        import std.typecons : scoped;

        // extract the boundaries of the enum to update the type db.
        auto vis = scoped!EnumVisitor(indent);
        vis.visit(v);
        ast.types.set(vis.id, vis.toType);
    }

    override void visit(const(FunctionDecl) v) @trusted {
        mixin(mixinNodeLog!());
        visitFunc(v);
    }

    override void visit(const(CxxMethod) v) {
        mixin(mixinNodeLog!());

        // model C++ methods as functions. It should be enough to know that it
        // is a function and the return type when generating mutants.
        visitFunc(v);
    }

    override void visit(const(CallExpr) v) {
        mixin(mixinNodeLog!());

        if (!visitOp(v)) {
            pushStack(new analyze.Call, v);
            v.accept(this);
        }
    }

    override void visit(const(BreakStmt) v) {
        mixin(mixinNodeLog!());
        v.accept(this);
    }

    override void visit(const BinaryOperator v) @trusted {
        mixin(mixinNodeLog!());
        visitOp(v);
    }

    override void visit(const UnaryOperator v) @trusted {
        mixin(mixinNodeLog!());
        visitOp(v);
    }

    override void visit(const CompoundAssignOperator v) {
        mixin(mixinNodeLog!());
        // TODO: implement all aor assignment such as +=
        pushStack(new analyze.OpAssign, v);
        v.accept(this);
    }

    override void visit(const CxxThrowExpr v) {
        mixin(mixinNodeLog!());
        // model a C++ exception as a return expression because that is
        // "basically" what happens.
        pushStack(new analyze.Return, v);
        v.accept(this);
    }

    override void visit(const(ReturnStmt) v) {
        mixin(mixinNodeLog!());
        pushStack(new analyze.Return, v);
        v.accept(this);
    }

    override void visit(const(CompoundStmt) v) {
        mixin(mixinNodeLog!());
        pushStack(new analyze.Block, v);
        v.accept(this);
    }

    override void visit(const CaseStmt v) {
        mixin(mixinNodeLog!());
        visitCaseStmt(v);
    }

    override void visit(const DefaultStmt v) {
        mixin(mixinNodeLog!());
        visitCaseStmt(v);
    }

    override void visit(const IfStmt v) @trusted {
        mixin(mixinNodeLog!());
        pushStack(new analyze.Block, v);
        dextool.plugin.mutate.backend.analyze.extensions.accept(v, this);
    }

    override void visit(const IfStmtCond v) {
        mixin(mixinNodeLog!());
        pushStack(new analyze.Condition, v);

        incr;
        scope (exit)
            decr;
        if (!visitOp(v)) {
            v.accept(this);
        }
    }

    override void visit(const IfStmtThen v) {
        mixin(mixinNodeLog!());
        pushStack(new analyze.Branch, v);
        v.accept(this);
    }

    override void visit(const IfStmtElse v) {
        mixin(mixinNodeLog!());
        pushStack(new analyze.Branch, v);
        v.accept(this);
    }

    private bool visitOp(T)(ref const T v) @trusted {
        auto op = operatorCursor(v);
        if (op.isNull) {
            return false;
        }

        if (visitBinaryOp(op.get))
            return true;
        return visitUnaryOp(op.get);
    }

    /// Returns: true if it added a binary operator, false otherwise.
    private bool visitBinaryOp(ref OperatorCursor op) @trusted {
        import cpptooling.analyzer.clang.ast : dispatch;

        auto astOp = cast(analyze.BinaryOp) op.astOp;
        if (astOp is null)
            return false;

        astOp.operator = op.operator;
        astOp.operator.blacklist = blacklist.inside(op.opLoc);

        op.put(nstack.back, ast);
        pushStack(astOp, op.exprLoc);
        incr;
        scope (exit)
            decr;

        if (op.lhs.isValid) {
            incr;
            scope (exit)
                decr;
            dispatch(op.lhs, this);
            auto b = () {
                if (!lastDecr.empty)
                    return cast(analyze.Expr) lastDecr[$ - 1];
                return null;
            }();
            if (b !is null && b != astOp) {
                astOp.lhs = b;
                auto ty = deriveCursorType(op.lhs);
                ty.put(ast);
                if (ty.type !is null) {
                    ast.put(b, ty.id);
                }
                if (ty.symbol !is null) {
                    ast.put(b, ty.symId);
                }
            }
        }
        if (op.rhs.isValid) {
            incr;
            scope (exit)
                decr;
            dispatch(op.rhs, this);
            auto b = () {
                if (!lastDecr.empty)
                    return cast(analyze.Expr) lastDecr[$ - 1];
                return null;
            }();
            if (b !is null && b != astOp) {
                astOp.rhs = b;
                auto ty = deriveCursorType(op.rhs);
                ty.put(ast);
                if (ty.type !is null) {
                    ast.put(b, ty.id);
                }
                if (ty.symbol !is null) {
                    ast.put(b, ty.symId);
                }
            }
        }

        return true;
    }

    /// Returns: true if it added a binary operator, false otherwise.
    private bool visitUnaryOp(ref OperatorCursor op) @trusted {
        import cpptooling.analyzer.clang.ast : dispatch;

        auto astOp = cast(analyze.UnaryOp) op.astOp;
        if (astOp is null)
            return false;

        astOp.operator = op.operator;
        astOp.operator.blacklist = blacklist.inside(op.opLoc);

        op.put(nstack.back, ast);
        pushStack(astOp, op.exprLoc);
        incr;
        scope (exit)
            decr;

        if (op.lhs.isValid) {
            incr;
            scope (exit)
                decr;
            dispatch(op.lhs, this);
            auto b = () {
                if (!lastDecr.empty)
                    return cast(analyze.Expr) lastDecr[$ - 1];
                return null;
            }();
            if (b !is null && b != astOp) {
                astOp.expr = b;
                auto ty = deriveCursorType(op.lhs);
                ty.put(ast);
                if (ty.type !is null) {
                    ast.put(b, ty.id);
                }
                if (ty.symbol !is null) {
                    ast.put(b, ty.symId);
                }
            }
        } else if (op.rhs.isValid) {
            incr;
            scope (exit)
                decr;
            dispatch(op.rhs, this);
            auto b = () {
                if (!lastDecr.empty)
                    return cast(analyze.Expr) lastDecr[$ - 1];
                return null;
            }();
            if (b !is null && b != astOp) {
                astOp.expr = b;
                auto ty = deriveCursorType(op.rhs);
                ty.put(ast);
                if (ty.type !is null) {
                    ast.put(b, ty.id);
                }
                if (ty.symbol !is null) {
                    ast.put(b, ty.symId);
                }
            }
        }

        return true;
    }

    private void visitFunc(T)(ref const T v) @trusted {
        auto loc = v.cursor.toLocation;
        auto n = new analyze.Function;
        ast.put(n, loc);
        nstack.back.children ~= n;
        pushStack(n, loc);

        auto fRetval = new analyze.Return;
        auto rty = deriveType(v.cursor.func.resultType);
        rty.put(ast);
        if (rty.type !is null) {
            ast.put(fRetval, loc);
            n.return_ = fRetval;
            ast.put(fRetval, rty.id);
        }
        if (rty.symbol !is null) {
            ast.put(fRetval, rty.symId);
        }

        v.accept(this);
    }

    private void visitCaseStmt(T)(ref const T v) @trusted {
        auto res = caseStmtCursor(v);
        if (res.isNull) {
            pushStack(new analyze.Block, v);
            v.accept(this);
            return;
        }

        auto branch = new analyze.Branch;
        ast.put(branch, res.get.branch);
        nstack.back.children ~= branch;
        pushStack(branch, res.get.branch);

        // create an node depth that diverge from the clang AST wherein the
        // inside of a case stmt is modelled as a block.
        incr;
        scope (exit)
            decr;
        auto inner = new analyze.Block;
        ast.put(inner, res.get.insideBranch);
        branch.children ~= inner;
        branch.inside = inner;
        pushStack(inner, res.get.insideBranch);
        dispatch(res.get.inner, this);
    }
}

final class EnumVisitor : ExtendedVisitor {
    import std.typecons : Nullable;
    import cpptooling.analyzer.clang.ast;

    alias visit = ExtendedVisitor.visit;

    mixin generateIndentIncrDecr;

    analyze.TypeId id;
    Nullable!long minValue;
    Nullable!long maxValue;

    this(const uint indent) {
        this.indent = indent;
    }

    override void visit(const EnumDecl v) @trusted {
        mixin(mixinNodeLog!());
        id = make!(analyze.TypeId)(v.cursor);
        v.accept(this);
    }

    override void visit(const EnumConstantDecl v) @trusted {
        mixin(mixinNodeLog!());

        long value = v.cursor.enum_.signedValue;

        if (minValue.isNull) {
            minValue = value;
            maxValue = value;
        }

        if (value < minValue.get)
            minValue = value;
        if (value > maxValue.get)
            maxValue = value;

        v.accept(this);
    }

    analyze.Type toType() const {
        auto l = () {
            if (minValue.isNull)
                return analyze.Value(analyze.Value.NegInf.init);
            return analyze.Value(analyze.Value.Int(minValue.get));
        }();
        auto u = () {
            if (maxValue.isNull)
                return analyze.Value(analyze.Value.PosInf.init);
            return analyze.Value(analyze.Value.Int(maxValue.get));
        }();

        return new analyze.DiscreteType(analyze.Range(l, u));
    }
}

enum discreteCategory = AliasSeq!(CXTypeKind.charU, CXTypeKind.uChar, CXTypeKind.char16,
            CXTypeKind.char32, CXTypeKind.uShort, CXTypeKind.uInt, CXTypeKind.uLong, CXTypeKind.uLongLong,
            CXTypeKind.uInt128, CXTypeKind.charS, CXTypeKind.sChar, CXTypeKind.wChar, CXTypeKind.short_,
            CXTypeKind.int_, CXTypeKind.long_, CXTypeKind.longLong,
            CXTypeKind.int128, CXTypeKind.enum_,);
enum floatCategory = AliasSeq!(CXTypeKind.float_, CXTypeKind.double_,
            CXTypeKind.longDouble, CXTypeKind.float128, CXTypeKind.half, CXTypeKind.float16,);
enum pointerCategory = AliasSeq!(CXTypeKind.nullPtr, CXTypeKind.pointer,
            CXTypeKind.blockPointer, CXTypeKind.memberPointer);
enum boolCategory = AliasSeq!(CXTypeKind.bool_);

struct DeriveTypeResult {
    analyze.TypeId id;
    analyze.Type type;
    analyze.SymbolId symId;
    analyze.Symbol symbol;

    void put(ref analyze.Ast ast) @safe {
        if (type !is null) {
            ast.types.require(id, type);
        }
        if (symbol !is null) {
            ast.symbols.require(symId, symbol);
        }
    }
}

DeriveTypeResult deriveType(Type cty) {
    DeriveTypeResult rval;

    auto ctydecl = cty.declaration;
    if (ctydecl.isValid) {
        rval.id = make!(analyze.TypeId)(ctydecl);
    } else {
        rval.id = make!(analyze.TypeId)(cty.cursor);
    }

    if (cty.isEnum) {
        rval.type = new analyze.DiscreteType(analyze.Range.makeInf);
        if (!cty.isSigned) {
            rval.type.range.low = analyze.Value(analyze.Value.Int(0));
        }
    } else if (cty.kind.among(floatCategory)) {
        rval.type = new analyze.ContinuesType(analyze.Range.makeInf);
    } else if (cty.kind.among(pointerCategory)) {
        rval.type = new analyze.UnorderedType(analyze.Range.makeInf);
    } else if (cty.kind.among(boolCategory)) {
        rval.type = new analyze.BooleanType(analyze.Range.makeBoolean);
    } else if (cty.kind.among(discreteCategory)) {
        rval.type = new analyze.DiscreteType(analyze.Range.makeInf);
        if (!cty.isSigned) {
            rval.type.range.low = analyze.Value(analyze.Value.Int(0));
        }
    }

    return rval;
}

struct DeriveCursorTypeResult {
    Cursor expr;
    DeriveTypeResult typeResult;
    alias typeResult this;
}

/** Analyze a cursor to derive the type of it and if it has a concrete value
 * and what it is in that case.
 *
 * This is intended for expression nodes in the clang AST.
 */
DeriveCursorTypeResult deriveCursorType(const Cursor baseCursor) {
    auto c = Cursor(getUnderlyingExprNode(baseCursor));
    if (!c.isValid)
        return DeriveCursorTypeResult.init;

    auto rval = DeriveCursorTypeResult(c);
    auto cty = c.type.canonicalType;
    rval.typeResult = deriveType(cty);

    // evaluate the cursor to add a value for the symbol
    void eval(const ref Eval e) {
        if (!e.kind.among(CXEvalResultKind.int_))
            return;

        const long value = () {
            if (e.isUnsignedInt) {
                const v = e.asUnsigned;
                if (v < long.max)
                    return cast(long) v;
            }
            return e.asLong;
        }();

        rval.symId = make!(analyze.SymbolId)(c);
        rval.symbol = new analyze.DiscretSymbol(analyze.Value(analyze.Value.Int(value)));
    }

    if (cty.isEnum) {
        // TODO: check if c.eval give the same result. If so it may be easier
        // to remove this special case of an enum because it is covered by the
        // generic branch for discretes.

        auto ctydecl = cty.declaration;
        if (!ctydecl.isValid)
            return rval;

        const cref = c.referenced;
        if (!cref.isValid)
            return rval;

        if (cref.kind == CXCursorKind.enumConstantDecl) {
            const long value = cref.enum_.signedValue;
            rval.symId = make!(analyze.SymbolId)(c);
            rval.symbol = new analyze.DiscretSymbol(analyze.Value(analyze.Value.Int(value)));
        }
    } else if (cty.kind.among(discreteCategory)) {
        // crashes in clang 7.x. Investigate why.
        //const e = c.eval;
        //if (e.isValid)
        //    eval(e);
    }

    return rval;
}

auto make(T)(const Cursor c) if (is(T == analyze.TypeId) || is(T == analyze.SymbolId)) {
    const usr = c.usr;
    if (usr.empty) {
        return T(c.toHash);
    }
    return analyze.makeId!T(usr);
}

/// trusted: trusting the impl in clang.
uint findTokenOffset(T)(T toks, Offset sr, CXTokenKind kind) @trusted {
    foreach (ref t; toks) {
        if (t.location.offset >= sr.end) {
            if (t.kind == kind) {
                return t.extent.end.offset;
            }
            break;
        }
    }

    return sr.end;
}

/** Create an index of all macros that then can be queried to see if a Cursor
 * or Interval overlap a macro.
 */
struct BlackList {
    Interval[][string] macros;

    this(const Cursor root) {
        Interval[][string] macros;

        foreach (c, parent; root.all) {
            if (c.kind != CXCursorKind.macroExpansion || c.isMacroBuiltin)
                continue;

            auto spelling = c.spelling;
            // C code almost always implement these as macros. They should not
            // be blocked from being mutated.
            if (spelling.among("bool", "TRUE", "FALSE"))
                continue;

            const file = c.location.path;
            const e = c.extent;
            const interval = Interval(e.start.offset, e.end.offset);
            if (auto v = file in macros) {
                (*v) ~= interval;
            } else {
                macros[file] = [interval];
            }
        }

        foreach (k; macros.byKey) {
            macros[k] = macros[k].sort.array;
        }

        this.macros = macros;
    }

    bool inside(const Cursor c) {
        const file = c.location.path.Path;
        const e = c.extent;
        const interval = Interval(e.start.offset, e.end.offset);
        return inside(file, interval);
    }

    bool inside(analyze.Location l) {
        return inside(l.file, l.interval);
    }

    /**
     * assuming that an invalid mutant is always inside a macro thus only
     * checking if the `i` is inside. Removing a "block" of code that happens
     * to contain a macro is totally "ok". It doesn't create any problem.
     *
     * Returns: true if `i` is inside a macro interval.
     */
    bool inside(const Path file, const Interval i) {
        static bool test(Interval i, uint p) {
            return p >= i.begin && p <= i.end;
        }

        if (auto intervals = file in macros) {
            foreach (a; *intervals) {
                if (test(a, i.begin) || test(a, i.end)) {
                    return true;
                }
            }
        }

        return false;
    }
}