use core::ffi::{CStr, c_void};

use pgrx::{Spi, is_a, pg_sys};

const MAX_VIEW_DEPTH: usize = 64;
type RequiredLineage = (pg_sys::Oid, pg_sys::AttrNumber);
type VarKey = (usize, pg_sys::AttrNumber);

#[pgrx::pg_extern(stable, strict)]
fn view_key_is_direct(view_oid: pg_sys::Oid, key_attno: i16) -> bool {
    if key_attno <= 0 {
        return false;
    }
    if Spi::get_one::<bool>(
        "SELECT pg_catalog.to_regclass('pgreact_internal.key_wrappers') IS NOT NULL",
    )
    .ok()
    .flatten()
    .unwrap_or(false)
        && Spi::get_one_with_args::<bool>(
        "SELECT EXISTS (SELECT 1 FROM pgreact_internal.key_wrappers WHERE wrapper_condition = $1)",
        &[view_oid.into()],
    )
        .ok()
        .flatten()
        .unwrap_or(false)
    {
        return true;
    }
    unsafe { direct_view_attribute(view_oid, key_attno, None, &mut Vec::new()) }
}

#[pgrx::pg_extern(stable, strict)]
fn view_key_is_direct_from(
    view_oid: pg_sys::Oid,
    key_attno: i16,
    required_view_oid: pg_sys::Oid,
    required_attno: i16,
) -> bool {
    if key_attno <= 0 || required_view_oid == pg_sys::InvalidOid || required_attno <= 0 {
        return false;
    }
    let mut occurrence_context = RequiredOccurrenceContext {
        required_view_oid,
        occurrences: 0,
        path: Vec::new(),
    };
    unsafe { count_view_occurrences(view_oid, &mut occurrence_context) };
    if occurrence_context.occurrences != 1 {
        return false;
    }
    unsafe {
        direct_view_attribute(
            view_oid,
            key_attno,
            Some((required_view_oid, required_attno)),
            &mut Vec::new(),
        )
    }
}

struct RequiredOccurrenceContext {
    required_view_oid: pg_sys::Oid,
    occurrences: usize,
    path: Vec<pg_sys::Oid>,
}

unsafe fn count_view_occurrences(view_oid: pg_sys::Oid, context: &mut RequiredOccurrenceContext) {
    unsafe { pg_sys::check_stack_depth() };
    if context.occurrences > 1 {
        return;
    }
    if view_oid == context.required_view_oid {
        context.occurrences += 1;
        return;
    }
    if context.path.len() >= MAX_VIEW_DEPTH || context.path.contains(&view_oid) {
        context.occurrences = 2;
        return;
    }
    context.path.push(view_oid);
    let relation = unsafe { pg_sys::relation_open(view_oid, pg_sys::AccessShareLock as i32) };
    let query = unsafe { pg_sys::get_view_query(relation) };
    if query.is_null() {
        context.occurrences = 2;
    } else {
        unsafe { count_query_occurrences(query, context) };
    }
    unsafe { pg_sys::relation_close(relation, pg_sys::AccessShareLock as i32) };
    context.path.pop();
}

unsafe fn count_query_occurrences(
    query: *mut pg_sys::Query,
    context: &mut RequiredOccurrenceContext,
) {
    unsafe { pg_sys::check_stack_depth() };
    if query.is_null() || context.occurrences > 1 {
        return;
    }
    let range_table = unsafe { (*query).rtable };
    for index in 0..unsafe { list_len(range_table) } {
        if context.occurrences > 1 {
            return;
        }
        let Some(entry) = (unsafe { list_ptr::<pg_sys::RangeTblEntry>(range_table, index) })
            .and_then(|entry| unsafe { entry.as_ref() })
        else {
            continue;
        };
        if !entry.inFromCl {
            continue;
        }
        match entry.rtekind {
            pg_sys::RTEKind::RTE_RELATION => {
                if entry.relid == context.required_view_oid {
                    context.occurrences += 1;
                } else if matches!(
                    entry.relkind as u8,
                    pg_sys::RELKIND_VIEW | pg_sys::RELKIND_MATVIEW
                ) {
                    unsafe { count_view_occurrences(entry.relid, context) };
                }
            }
            pg_sys::RTEKind::RTE_SUBQUERY => unsafe {
                count_query_occurrences(entry.subquery, context)
            },
            pg_sys::RTEKind::RTE_CTE if entry.ctelevelsup == 0 => unsafe {
                count_cte_occurrences(query, entry, context)
            },
            _ => {}
        }
    }
    let flags = (pg_sys::QTW_IGNORE_RANGE_TABLE
        | pg_sys::QTW_IGNORE_CTE_SUBQUERIES
        | pg_sys::QTW_IGNORE_RT_SUBQUERIES) as i32;
    unsafe {
        pg_sys::query_tree_walker_impl(
            query,
            Some(count_nested_query_occurrences),
            context as *mut RequiredOccurrenceContext as *mut c_void,
            flags,
        )
    };
}

unsafe extern "C-unwind" fn count_nested_query_occurrences(
    node: *mut pg_sys::Node,
    raw_context: *mut c_void,
) -> bool {
    unsafe { pg_sys::check_stack_depth() };
    if node.is_null() || raw_context.is_null() {
        return false;
    }
    let context = unsafe { &mut *raw_context.cast::<RequiredOccurrenceContext>() };
    if context.occurrences > 1 {
        return true;
    }
    if unsafe { is_a(node, pg_sys::NodeTag::T_Query) } {
        unsafe { count_query_occurrences(node.cast(), context) };
        return context.occurrences > 1;
    }
    unsafe {
        pg_sys::expression_tree_walker_impl(node, Some(count_nested_query_occurrences), raw_context)
    }
}

unsafe fn count_cte_occurrences(
    query: *mut pg_sys::Query,
    entry: &pg_sys::RangeTblEntry,
    context: &mut RequiredOccurrenceContext,
) {
    if entry.ctename.is_null() {
        context.occurrences = 2;
        return;
    }
    let name = unsafe { CStr::from_ptr(entry.ctename) };
    let ctes = unsafe { (*query).cteList };
    let mut found = false;
    for index in 0..unsafe { list_len(ctes) } {
        let Some(cte) = (unsafe {
            list_ptr::<pg_sys::CommonTableExpr>(ctes, index).and_then(|cte| cte.as_ref())
        }) else {
            continue;
        };
        if cte.ctename.is_null() || unsafe { CStr::from_ptr(cte.ctename) } != name {
            continue;
        }
        found = true;
        if cte.cterecursive || !unsafe { is_a(cte.ctequery, pg_sys::NodeTag::T_Query) } {
            context.occurrences = 2;
        } else {
            unsafe { count_query_occurrences(cte.ctequery.cast(), context) };
        }
        break;
    }
    if !found {
        context.occurrences = 2;
    }
}

#[pgrx::pg_extern(stable, strict)]
fn view_key_uses_operator(view_oid: pg_sys::Oid, key_attno: i16) -> bool {
    if key_attno <= 0 {
        return false;
    }
    unsafe { view_attribute_uses_operator(view_oid, key_attno, &mut Vec::new()) }
}

unsafe fn direct_view_attribute(
    view_oid: pg_sys::Oid,
    attribute: pg_sys::AttrNumber,
    required: Option<RequiredLineage>,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    if required == Some((view_oid, attribute)) {
        return true;
    }
    if path.len() >= MAX_VIEW_DEPTH || path.contains(&(view_oid, attribute)) {
        return false;
    }
    path.push((view_oid, attribute));
    let relation = unsafe { pg_sys::relation_open(view_oid, pg_sys::AccessShareLock as i32) };
    let query = unsafe { pg_sys::get_view_query(relation) };
    let result =
        !query.is_null() && unsafe { direct_query_attribute(query, attribute, required, path) };
    unsafe { pg_sys::relation_close(relation, pg_sys::AccessShareLock as i32) };
    path.pop();
    result
}

unsafe fn direct_query_attribute(
    query: *mut pg_sys::Query,
    attribute: pg_sys::AttrNumber,
    required: Option<RequiredLineage>,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    unsafe { pg_sys::check_stack_depth() };
    if query.is_null() || attribute <= 0 {
        return false;
    }
    unsafe { query_attribute_expression(query, attribute) }.is_some_and(|expression| unsafe {
        direct_expression_matches(query, expression, required, path)
    })
}

unsafe fn direct_expression(
    query: *mut pg_sys::Query,
    expression: *mut pg_sys::Expr,
    required: Option<RequiredLineage>,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    unsafe { pg_sys::check_stack_depth() };
    if expression.is_null() || !unsafe { is_a(expression.cast(), pg_sys::NodeTag::T_Var) } {
        return false;
    }
    let variable = unsafe { &*(expression.cast::<pg_sys::Var>()) };
    if variable.varlevelsup != 0 || variable.varno <= 0 || variable.varattno <= 0 {
        return false;
    }
    unsafe {
        direct_variable(
            query,
            variable.varno as usize,
            variable.varattno,
            required,
            path,
        )
    }
}

unsafe fn direct_variable(
    query: *mut pg_sys::Query,
    variable_number: usize,
    attribute: pg_sys::AttrNumber,
    required: Option<RequiredLineage>,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    let range_table = unsafe { (*query).rtable };
    let Some(entry) =
        (unsafe { list_ptr::<pg_sys::RangeTblEntry>(range_table, variable_number - 1) })
            .and_then(|entry| unsafe { entry.as_ref() })
    else {
        return false;
    };
    match entry.rtekind {
        pg_sys::RTEKind::RTE_RELATION => {
            if matches!(
                entry.relkind as u8,
                pg_sys::RELKIND_VIEW | pg_sys::RELKIND_MATVIEW
            ) {
                unsafe { direct_view_attribute(entry.relid, attribute, required, path) }
            } else {
                required.is_none()
            }
        }
        pg_sys::RTEKind::RTE_SUBQUERY => unsafe {
            direct_query_attribute(entry.subquery, attribute, required, path)
        },
        pg_sys::RTEKind::RTE_JOIN => {
            unsafe { list_ptr::<pg_sys::Expr>(entry.joinaliasvars, attribute as usize - 1) }
                .is_some_and(|alias| unsafe { direct_expression(query, alias, required, path) })
        }
        pg_sys::RTEKind::RTE_CTE if entry.ctelevelsup == 0 => unsafe {
            direct_cte_attribute(query, entry, attribute, required, path)
        },
        _ => false,
    }
}

unsafe fn direct_expression_matches(
    query: *mut pg_sys::Query,
    expression: *mut pg_sys::Expr,
    required: Option<RequiredLineage>,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    if unsafe { direct_expression(query, expression, required, path) } {
        return true;
    }
    let Some(required) = required else {
        return false;
    };
    let Some(start) = (unsafe { expression_var_key(query, expression) }) else {
        return false;
    };
    let mut equalities = Vec::new();
    unsafe { collect_jointree_equalities(query, &mut equalities) };
    let mut equivalents = vec![start];
    let mut index = 0;
    while index < equivalents.len() {
        let current = equivalents[index];
        for &(left, right) in &equalities {
            let next = if left == current {
                Some(right)
            } else if right == current {
                Some(left)
            } else {
                None
            };
            if let Some(next) = next.filter(|next| !equivalents.contains(next)) {
                equivalents.push(next);
            }
        }
        index += 1;
    }
    equivalents
        .into_iter()
        .skip(1)
        .any(|(varno, attno)| unsafe { direct_variable(query, varno, attno, Some(required), path) })
}

unsafe fn direct_cte_attribute(
    query: *mut pg_sys::Query,
    entry: &pg_sys::RangeTblEntry,
    attribute: pg_sys::AttrNumber,
    required: Option<RequiredLineage>,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    if entry.ctename.is_null() {
        return false;
    }
    let name = unsafe { CStr::from_ptr(entry.ctename) };
    let ctes = unsafe { (*query).cteList };
    (0..unsafe { list_len(ctes) }).any(|index| {
        let Some(cte) = (unsafe {
            list_ptr::<pg_sys::CommonTableExpr>(ctes, index).and_then(|cte| cte.as_ref())
        }) else {
            return false;
        };
        if cte.ctename.is_null()
            || cte.cterecursive
            || unsafe { CStr::from_ptr(cte.ctename) } != name
            || !unsafe { is_a(cte.ctequery, pg_sys::NodeTag::T_Query) }
        {
            return false;
        }
        unsafe { direct_query_attribute(cte.ctequery.cast(), attribute, required, path) }
    })
}

unsafe fn query_attribute_expression(
    query: *mut pg_sys::Query,
    attribute: pg_sys::AttrNumber,
) -> Option<*mut pg_sys::Expr> {
    let targets = unsafe { (*query).targetList };
    (0..unsafe { list_len(targets) }).find_map(|index| {
        let target = unsafe { list_ptr::<pg_sys::TargetEntry>(targets, index)?.as_ref()? };
        (!target.resjunk && target.resno == attribute).then_some(target.expr)
    })
}

unsafe fn expression_var_key(
    query: *mut pg_sys::Query,
    expression: *mut pg_sys::Expr,
) -> Option<VarKey> {
    if expression.is_null() || !unsafe { is_a(expression.cast(), pg_sys::NodeTag::T_Var) } {
        return None;
    }
    let variable = unsafe { &*expression.cast::<pg_sys::Var>() };
    if variable.varlevelsup != 0 || variable.varno <= 0 || variable.varattno <= 0 {
        return None;
    }
    let key = (variable.varno as usize, variable.varattno);
    let entry = unsafe { list_ptr::<pg_sys::RangeTblEntry>((*query).rtable, key.0 - 1)?.as_ref()? };
    if entry.rtekind != pg_sys::RTEKind::RTE_JOIN {
        return Some(key);
    }
    let alias = unsafe { list_ptr::<pg_sys::Expr>(entry.joinaliasvars, key.1 as usize - 1)? };
    unsafe { expression_var_key(query, alias) }
}

unsafe fn collect_jointree_equalities(
    query: *mut pg_sys::Query,
    output: &mut Vec<(VarKey, VarKey)>,
) {
    unsafe { pg_sys::check_stack_depth() };
    unsafe { collect_from_equalities(query, (*query).jointree.cast(), output) };
}

unsafe fn collect_from_equalities(
    query: *mut pg_sys::Query,
    node: *mut pg_sys::Node,
    output: &mut Vec<(VarKey, VarKey)>,
) {
    unsafe { pg_sys::check_stack_depth() };
    if node.is_null() {
        return;
    }
    match unsafe { (*node).type_ } {
        pg_sys::NodeTag::T_FromExpr => {
            let from = unsafe { &*node.cast::<pg_sys::FromExpr>() };
            for index in 0..unsafe { list_len(from.fromlist) } {
                if let Some(child) = unsafe { list_ptr::<pg_sys::Node>(from.fromlist, index) } {
                    unsafe { collect_from_equalities(query, child, output) };
                }
            }
            unsafe { collect_qual_equalities(query, from.quals, output) };
        }
        pg_sys::NodeTag::T_JoinExpr => {
            let join = unsafe { &*node.cast::<pg_sys::JoinExpr>() };
            unsafe { collect_from_equalities(query, join.larg, output) };
            unsafe { collect_from_equalities(query, join.rarg, output) };
            unsafe { collect_qual_equalities(query, join.quals, output) };
        }
        _ => {}
    }
}

unsafe fn collect_qual_equalities(
    query: *mut pg_sys::Query,
    node: *mut pg_sys::Node,
    output: &mut Vec<(VarKey, VarKey)>,
) {
    unsafe { pg_sys::check_stack_depth() };
    if node.is_null() {
        return;
    }
    match unsafe { (*node).type_ } {
        pg_sys::NodeTag::T_BoolExpr => {
            let boolean = unsafe { &*node.cast::<pg_sys::BoolExpr>() };
            if boolean.boolop != pg_sys::BoolExprType::AND_EXPR {
                return;
            }
            for index in 0..unsafe { list_len(boolean.args) } {
                if let Some(argument) = unsafe { list_ptr::<pg_sys::Node>(boolean.args, index) } {
                    unsafe { collect_qual_equalities(query, argument, output) };
                }
            }
        }
        pg_sys::NodeTag::T_OpExpr => {
            let operator = unsafe { &*node.cast::<pg_sys::OpExpr>() };
            if unsafe { list_len(operator.args) } != 2 {
                return;
            }
            let Some(left) = (unsafe { list_ptr::<pg_sys::Expr>(operator.args, 0) }) else {
                return;
            };
            let Some(right) = (unsafe { list_ptr::<pg_sys::Expr>(operator.args, 1) }) else {
                return;
            };
            if !unsafe { pg_sys::op_hashjoinable(operator.opno, pg_sys::exprType(left.cast())) } {
                return;
            }
            if let (Some(left), Some(right)) =
                (unsafe { expression_var_key(query, left) }, unsafe {
                    expression_var_key(query, right)
                })
            {
                output.push((left, right));
            }
        }
        _ => {}
    }
}

unsafe fn view_attribute_uses_operator(
    view_oid: pg_sys::Oid,
    attribute: pg_sys::AttrNumber,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    if path.len() >= MAX_VIEW_DEPTH || path.contains(&(view_oid, attribute)) {
        return false;
    }
    path.push((view_oid, attribute));
    let relation = unsafe { pg_sys::relation_open(view_oid, pg_sys::AccessShareLock as i32) };
    let query = unsafe { pg_sys::get_view_query(relation) };
    let result =
        !query.is_null() && unsafe { query_attribute_uses_operator(query, attribute, path) };
    unsafe { pg_sys::relation_close(relation, pg_sys::AccessShareLock as i32) };
    path.pop();
    result
}

unsafe fn query_attribute_uses_operator(
    query: *mut pg_sys::Query,
    attribute: pg_sys::AttrNumber,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    unsafe { pg_sys::check_stack_depth() };
    unsafe { query_attribute_expression(query, attribute) }
        .is_some_and(|expression| unsafe { expression_uses_operator(query, expression, path) })
}

unsafe fn expression_uses_operator(
    query: *mut pg_sys::Query,
    expression: *mut pg_sys::Expr,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    unsafe { pg_sys::check_stack_depth() };
    if expression.is_null() {
        return false;
    }
    if unsafe { is_a(expression.cast(), pg_sys::NodeTag::T_OpExpr) } {
        return true;
    }
    let Some((varno, attno)) = (unsafe { expression_var_key(query, expression) }) else {
        return false;
    };
    let Some(entry) = (unsafe { list_ptr::<pg_sys::RangeTblEntry>((*query).rtable, varno - 1) })
        .and_then(|entry| unsafe { entry.as_ref() })
    else {
        return false;
    };
    match entry.rtekind {
        pg_sys::RTEKind::RTE_RELATION
            if matches!(
                entry.relkind as u8,
                pg_sys::RELKIND_VIEW | pg_sys::RELKIND_MATVIEW
            ) =>
        unsafe { view_attribute_uses_operator(entry.relid, attno, path) },
        pg_sys::RTEKind::RTE_SUBQUERY => unsafe {
            query_attribute_uses_operator(entry.subquery, attno, path)
        },
        pg_sys::RTEKind::RTE_CTE if entry.ctelevelsup == 0 => unsafe {
            cte_attribute_uses_operator(query, entry, attno, path)
        },
        _ => false,
    }
}

unsafe fn cte_attribute_uses_operator(
    query: *mut pg_sys::Query,
    entry: &pg_sys::RangeTblEntry,
    attribute: pg_sys::AttrNumber,
    path: &mut Vec<(pg_sys::Oid, pg_sys::AttrNumber)>,
) -> bool {
    if entry.ctename.is_null() {
        return false;
    }
    let name = unsafe { CStr::from_ptr(entry.ctename) };
    let ctes = unsafe { (*query).cteList };
    (0..unsafe { list_len(ctes) }).any(|index| {
        let Some(cte) = (unsafe {
            list_ptr::<pg_sys::CommonTableExpr>(ctes, index).and_then(|cte| cte.as_ref())
        }) else {
            return false;
        };
        !cte.ctename.is_null()
            && !cte.cterecursive
            && unsafe { CStr::from_ptr(cte.ctename) } == name
            && unsafe { is_a(cte.ctequery, pg_sys::NodeTag::T_Query) }
            && unsafe { query_attribute_uses_operator(cte.ctequery.cast(), attribute, path) }
    })
}

unsafe fn list_len(list: *mut pg_sys::List) -> usize {
    if list.is_null() || unsafe { (*list).type_ } != pg_sys::NodeTag::T_List {
        return 0;
    }
    unsafe { (*list).length.max(0) as usize }
}

unsafe fn list_ptr<T>(list: *mut pg_sys::List, index: usize) -> Option<*mut T> {
    if index >= unsafe { list_len(list) } || unsafe { (*list).elements.is_null() } {
        return None;
    }
    Some(unsafe { (*(*list).elements.add(index)).ptr_value.cast() })
}
