# An S3 shim on top of DBI.  The goal is to isolate all DBI calls into this
# file, so that when writing new connectors you can see all the existing
# code in one place, and hopefully remember the annoying DBI function names.
#
# * db_ -> con = DBIConnection
# * qry_ -> con = DBIConnection, sql = string
# * res_ -> res = DBIResult
# * sql_ -> con = DBIConnection, table = string, ...
#
# This also makes it possible to shim over bugs in packages until they're
# fixed upstream.

#' Database generics.
#'
#' These three generics are used to get information about the database.
#' dplyr provides default methods for DBIConnection which call the DBI
#' equivalents, \code{dbListTables}, \code{dbExistsTable} and \code{dbDataType}.
#' It should be rarely necessary to provide more specific methods for
#' DBI compliant interfaces.
#'
#' @name dbi-database
#' @param con A database connection.
#' @keywords internal
NULL

#' @rdname dbi-database
#' @export
db_list_tables <- function(con) UseMethod("db_list_tables")
#' @export
db_list_tables.DBIConnection <- function(con) DBI::dbListTables(con)

#' @rdname dbi-database
#' @export
#' @param table A string, the table name.
db_has_table <- function(con, table) UseMethod("db_has_table")
#' @export
db_has_table.DBIConnection <- function(con, table) DBI::dbExistsTable(con, table)

#' @rdname dbi-database
#' @export
#' @param fields A list of fields, as in a data frame.
db_data_type <- function(con, fields) UseMethod("db_data_type")
#' @export
db_data_type.DBIConnection <- function(con, fields) {
  vapply(fields, DBI::dbDataType, dbObj = con, FUN.VALUE = character(1))
}

# Query details ----------------------------------------------------------------

qry_fields <- function(con, from) {
  UseMethod("qry_fields")
}
#' @export
qry_fields.DBIConnection <- function(con, from) {
  qry <- dbSendQuery(con, build_sql("SELECT * FROM ", from, " WHERE 0=1;"))
  on.exit(dbClearResult(qry))

  DBI::dbGetInfo(qry)$fieldDescription[[1]]$name
}

# SQL queries ------------------------------------------------------------------

#' SQL generics.
#'
#' These generics are used to run various types of SQL queries.
#' Default methods are provides for \code{DBIConnection}, but variations in
#' SQL across databases means that it's likely that each backend will require
#' a few variations of these.
#'
#' @section copy_to:
#' Currently, the only user of \code{sql_begin()}, \code{sql_commit()},
#' \code{sql_rollback()}, \code{sql_create_table()}, \code{sql_insert_into()},
#' \code{sql_create_indexes()}, \code{sql_drop_table()} and
#' \code{sql_analyze()}. If you find yourself overriding many of these
#' functions it may suggest that you should just override \code{\link{copy_to}}
#' instead.
#'
#' @name dbi-sql
#' @param con A database connection.
#' @keywords internal
NULL

#' @rdname dbi-sql
#' @export
sql_begin <- function(con, ...) UseMethod("sql_begin")
#' @export
sql_begin.DBIConnection <- function(con, ...) {
  dbGetQuery(con, "BEGIN TRANSACTION")
}

#' @rdname dbi-sql
#' @export
sql_commit <- function(con, ...) UseMethod("sql_commit")
#' @export
sql_commit.DBIConnection <- function(con, ...) dbCommit(con)

#' @rdname dbi-sql
#' @export
sql_rollback <- function(con, ...) UseMethod("sql_rollback")
#' @export
sql_rollback.DBIConnection <- function(con, ...) dbRollback(con)

#' @rdname dbi-sql
#' @export
sql_create_table <- function(con, table, types, temporary = FALSE, ...) {
  UseMethod("sql_create_table")
}
#' @export
sql_create_table.DBIConnection <- function(con, table, types,
                                           temporary = FALSE, ...) {
  assert_that(is.string(table), is.character(types))

  field_names <- escape(ident(names(types)), collapse = NULL, con = con)
  fields <- sql_vector(paste0(field_names, " ", types), parens = TRUE,
    collapse = ", ", con = con)
  sql <- build_sql("CREATE ", if (temporary) sql("TEMPORARY "),
    "TABLE ", ident(table), " ", fields, con = con)

  dbGetQuery(con, sql)
}

#' @rdname dbi-sql
#' @export
sql_insert_into <- function(con, table, values, ...) {
  UseMethod("sql_insert_into")
}

#' @rdname dbi-sql
#' @export
sql_create_indexes <- function(con, table, indexes = NULL, ...) {
  UseMethod("sql_create_indexes")
}
#' @export
sql_create_indexes.DBIConnection <- function(con, table, indexes = NULL, ...) {
  if (is.null(indexes)) return()
  assert_that(is.list(indexes))

  for(index in indexes) {
    sql_create_index(con, table, index, ...)
  }
}

sql_create_index <- function(con, table, columns, name = NULL, unique = FALSE) {
  assert_that(is.string(table), is.character(columns))

  name <- name %||% paste0(c(table, columns), collapse = "_")

  fields <- escape(ident(columns), parens = TRUE, con = con)
  sql <- build_sql("CREATE ", if (unique) sql("UNIQUE "), "INDEX ", ident(name),
    " ON ", ident(table), " ", fields, con = con)

  dbGetQuery(con, sql)
}

#' @rdname dbi-sql
#' @export
sql_drop_table <- function(con, table, force = FALSE, ...) {
  UseMethod("sql_drop_table")
}
#' @export
sql_drop_table.DBIConnection <- function(con, table, force = FALSE, ...) {
  sql <- build_sql("DROP TABLE ", if (force) sql("IF EXISTS "), ident(table),
    con = con)
  dbGetQuery(con, sql)
}

#' @rdname dbi-sql
#' @export
sql_analyze <- function(con, table, ...) UseMethod("sql_analyze")
#' @export
sql_analyze.DBIConnection <- function(con, table, ...) {
  sql <- build_sql("ANALYZE ", ident(table), con = con)
  dbGetQuery(con, sql)
}

#' @rdname dbi-sql
#' @export
sql_select <- function(con, select, from, where = NULL, group_by = NULL,
  having = NULL, order_by = NULL, limit = NULL, offset = NULL, ...) {
  UseMethod("sql_select")
}

#' @export
sql_select.DBIConnection <- function(con, select, from, where = NULL,
                                     group_by = NULL, having = NULL,
                                     order_by = NULL, limit = NULL,
                                     offset = NULL, ...) {

  out <- vector("list", 8)
  names(out) <- c("select", "from", "where", "group_by", "having", "order_by",
    "limit", "offset")

  assert_that(is.character(select), length(select) > 0L)
  out$select <- build_sql("SELECT ", escape(select, collapse = ", ", con = con))

  assert_that(is.character(from), length(from) == 1L)
  out$from <- build_sql("FROM ", from, con = con)

  if (length(where) > 0L) {
    assert_that(is.character(where))
    out$where <- build_sql("WHERE ",
      escape(where, collapse = " AND ", con = con))
  }

  if (!is.null(group_by)) {
    assert_that(is.character(group_by), length(group_by) > 0L)
    out$group_by <- build_sql("GROUP BY ",
      escape(group_by, collapse = ", ", con = con))
  }

  if (!is.null(having)) {
    assert_that(is.character(having), length(having) == 1L)
    out$having <- build_sql("HAVING ",
      escape(having, collapse = ", ", con = con))
  }

  if (!is.null(order_by)) {
    assert_that(is.character(order_by), length(order_by) > 0L)
    out$order_by <- build_sql("ORDER BY ",
      escape(order_by, collapse = ", ", con = con))
  }

  if (!is.null(limit)) {
    assert_that(is.integer(limit), length(limit) == 1L)
    out$limit <- build_sql("LIMIT ", limit, con = con)
  }

  if (!is.null(offset)) {
    assert_that(is.integer(offset), length(offset) == 1L)
    out$offset <- build_sql("OFFSET ", offset, con = con)
  }

  escape(unname(compact(out)), collapse = "\n", parens = FALSE, con = con)
}

#' @export
#' @rdname dbi-sql
sql_explain <- function(con, sql, ...) {
  UseMethod("sql_explain")
}

# Utility functions ------------------------------------------------------------

random_table_name <- function(n = 10) {
  paste0(sample(letters, n, replace = TRUE), collapse = "")
}

# Creates an environment that disconnects the database when it's
# garbage collected
db_disconnector <- function(con, name, quiet = FALSE) {
  reg.finalizer(environment(), function(...) {
    if (!quiet) {
      message("Auto-disconnecting ", name, " connection ",
        "(", paste(con@Id, collapse = ", "), ")")
    }
    dbDisconnect(con)
  })
  environment()
}

res_warn_incomplete <- function(res) {
  if (dbHasCompleted(res)) return()

  rows <- formatC(dbGetRowCount(res), big.mark = ",")
  warning("Only first ", rows, " results retrieved. Use n = -1 to retrieve all.",
    call. = FALSE)
}

