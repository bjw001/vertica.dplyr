####################################################################
#A dplyr connector for the Vector database.
#Copyright (C) [2015] Hewlett-Packard Development Company, L.P.

#This program is free software; you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation; either version 2 of the License, or (at
#your option) any later version.

#This program is distributed in the hope that it will be useful, but
#WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#General Public License for more details.  You should have received a
#copy of the GNU General Public License along with this program; if
#not, write to the Free Software Foundation, Inc., 59 Temple Place,
#Suite 330, Boston, MA 02111-1307 USA
#####################################################################

setClass("VectorConnection", representation = representation(conn = "ANY", type = "character"))

.VectorConnection <- function(conn,type) {
  new("VectorConnection",conn=conn,type=type)
}

#' Establishes a connection to Vector and returns a dplyr 'src' object, src_vector, using either vRODBC or JDBC.
#'
#' Provide either the DSN to use ODBC, or set DSN to NULL to use JDBC.
#'
#' @param dsn The name of the ODBC DSN to use for connecting to Vector. Must be a string. If NULL, JDBC-use is assumed.
#' @param jdbcpath (Only required for JDBC) Path to the JDBC driver on your system.
#' @param dbname (Only required for JDBC) The name of the Vector database instance that you plan to connect to.
#' @param host (Only required for JDBC) Host IP of the machine hosting the Vector instance.
#' @param port (Only required for JDBC) Port number of the Vector server. The Vector default is 5433.
#' @param user (Only required for JDBC) Username of the owner of the database.
#' @param password (Only required for JDBC) Password, if any, of the database.
#' @param load_udf A boolean value. If TRUE (default), this will automatically register the UDFs into the session.
#' @return A dplyr::src object, src_vector, to be used with dplyr functions.
#' @examples
#' \dontrun{
#' Vector_connection <- src_vector(dsn="VectorDSN")
#' Vector_connection <- src_vector(dsn=NULL,jdbcpath="/opt/vector/java/lib/iidb_jdbc.jar",
#'                                   dbname="foo",host="localhost",port=5433,
#'                                   user="dbadmin",password="secret")
#' }
#' @import methods
#' @import assertthat
#' @import dplyr
#' @export
src_vector <- function(dsn = NULL, jdbcpath = NULL, dbname = NULL, host = NULL, port = AP7, user = NULL, password = "", load_udf=TRUE) {
  if(is.null(jdbcpath) && is.null(dsn)){
    stop("Must provide either the ODBC DSN driver name or the CLASSPATH to your Vector JDBC Driver, e.g., src_vector(...,dsn=\"VectorDSN\") or src_vector(...,jdbcpath=\"/opt/Vector/java/lib/Vector_jdbc.jar\")")
  }
 
  if(!is.null(dsn)) {
    .attemptLoad("vRODBC")
    odbcCloseAll()
    assert_that(is.character(dsn))
    conn <- odbcConnect(dsn)
    info <- odbcGetInfo(conn)  
    type <- "ODBC"
  }else {
    assert_that(is.character(jdbcpath))
    #assert_that(is.numeric(port))
    .attemptLoad("RJDBC")
    host <- as.character(host)
    port <- as.character(port)
    type <- "JDBC"
  
    drv <- JDBC(driverClass = "com.ingres.jdbc.IngresDriver",classPath = jdbcpath)
    conn <- dbConnect(drv,paste0("jdbc:ingres://",host,":",port,"/",dbname),user=user,password=password)
  }

  con <- .VectorConnection(conn=conn,type=type)

  if(checkDB(con)){
    if(type=="JDBC"){
      info <- list()
      info$host <- host
      info$port <- port
      info$user <- user
      info$dbname <- dbname
      info$type <- paste0(type, " Connection")
    }
  } else {
    stop("Stop error: Could not establish a valid connection to a Vector database.")
  }

  vsrc <- src_sql("vector", con = con, info = info)

  #if(load_udf) {
  #  import_udf(vsrc)
  #}
  
  vsrc
}

# Describes the connection
#' @export
src_desc.src_vector <- function(x) {
  info <- x$info
    
  if(x$con@type == "JDBC"){
    host <- ifelse(is.null(info$host),"localhost",info$host)

    paste0("Vector ", info$type, " [", info$user, "@",
      host, ":", info$port, "/", info$dbname, "]")
  }else{
    paste0("Vector ", "ODBC Connection", "\n-----+DSN: ",info["Data_Source_Name"], "\n-----+Host: ", info["Server_Name"], 
    "\n-----+DB Version: ", info["DBMS_Ver"], "\n-----+ODBC Version: ", info["Driver_ODBC_Ver"])
  }
}

#' @export
tbl.src_vector <- function(src, from, ...) {
  tbl_sql("Vector", src = src, from = from, ...)
}

#' @export
query.VectorConnection <- function(con, sql, .vars) {
  assert_that(is.string(sql))
  Vector.Query$new(con, sql(sql), .vars)
}

Vector.Query <- R6::R6Class("Vector.Query",
  private = list(
    .nrow = NULL,
    .vars = NULL
  ),
  public = list(
    con = NULL,
    sql = NULL,

    initialize = function(con, sql, vars) {
      self$con <- con
      self$sql <- sql
      private$.vars <- vars
    },

    print = function(...) {
      cat("<Query> ", self$sql, "\n", sep = "")
      print(self$con)
    },

    fetch = function(n = -1L) {
      if(self$con@type == "ODBC") {
        out <- sqlQuery(self$con@conn, self$sql, n)
        i <- sapply(out, is.factor)
        out[i] <- lapply(out[i], as.character)
      }else { 
        res <- dbSendQuery(self$con@conn, self$sql)
        on.exit(dbClearResult(res))

        out <- fetch(res, n)
        dplyr:::res_warn_incomplete(res)
      }
      out
    },

    fetch_paged = function(chunk_size = 1e4, callback) {
      stop("Temporarily unsupported operation")
      qry <- dbSendQuery(self$con, self$sql)
      on.exit(dbClearResult(qry))

      while (!dbHasCompleted(qry)) {
        chunk <- fetch(qry, chunk_size)
        callback(chunk)
      }

      invisible(TRUE)
    },

    vars = function() {
      private$.vars
    },

    nrow = function() {
      if (!is.null(private$.nrow)) return(private$.nrow)
      private$.nrow <- db_query_rows(self$con, self$sql)
      private$.nrow
    },

    ncol = function() {
      length(self$vars())
    }
  )
)

#' Loads a file (typically CSV) from disk to Vector.
#'
#' Currently, this will only work for tables that already exist with compatible
#' schema for the table.
#'
#' This loading is fast and is used (by default) in copy_to.
#'
#' @param dest Vector connection src to the DB.
#' @param table.name The name of the table created in Vector matching the schema
#' of the file.
#' @param file.name Path to file with data.
#' @param sep Delimiter in the file.
#' @param skip Number of lines to skip at the beginning of the file (useful if contains headers).
#' @param append TRUE if copied data will be added to existing data in table. FALSE to overwrite table data.
#' @return A new tbl_Vector reference to the loaded table.
#' @examples
#' \dontrun{
#' Vector <- src_vector("VectorDSN")
#' foo <- db_load_from_file(Vector,"foo","./foo.csv",sep=",")
#' }
#' @export
db_load_from_file <- function(dest, table.name, file.name, sep = " ", skip = 1L, append = FALSE){
  assert_that(is.character(table.name))
  assert_that(is.character(file.name), file.exists(file.name))

  assert_that(is.character(sep))
  assert_that(class(dest)[1] == "src_vector")

  if(!db_has_table(dest$con, table.name)) stop("The specified table does not exist in Vector.")

  skip <- ifelse(skip >=0,as.integer(skip),0L)

  itable <- ident_schema_table(table.name)

  if(!append) {
    delete_sql <- build_sql("DELETE FROM ", itable)
    send_query(dest$con@conn, delete_sql)
  }

  copy_sql <- build_sql("COPY ", itable, " FROM LOCAL ", file.name,
         " WITH DELIMITER AS ", sep, " NULL AS 'NA'", " SKIP ", skip, " ABORT ON ERROR", con = dest$con)

  tryCatch({result = send_query(dest$con@conn, copy_sql)
            if(class(result) == "character" 
               && length(result) >=2
               && substring(result[2],1,14) == "[vRODBC] ERROR")
                 {
                   stop(result)
                 }
           },
           warning=function(w) {
             warning(w)}, 
           error = function(e) {
             stop(e)}
          )   
             
  tbl(dest, table.name)
} 

#' @export
copy_to.src_vector <- function(dest, df, name = deparse(substitute(df)),
                           temporary=FALSE, append=FALSE, fast.load=TRUE, ...) {

  assert_that(is.data.frame(df), is.string(name))
  has_table <- db_has_table(dest$con, name)

  if(!append) {

    if(has_table) {
      warning(name, " already exists.")
      ans <- readline(prompt = paste0("Replace existing table named `", name, "`?(y/n) "))
      if(substring(ans,1,1) != "y" && substring(ans,1,1) != "Y") return()
      else db_drop_table(dest$con, name)
    }

    types <- db_data_type(dest$con, df)
    names(types) <- names(df)

    if(temporary) warning("Copying to a temporary table is not supported. Writing to a permanent table.")
    db_create_table(dest$con, name, types, temporary=FALSE)
  } else {
    if(!has_table)
      stop("Cannot append to non-existing table ", name, ".")
  }

  if(fast.load) {
    tmpfilename = paste0("/tmp/", "dplyr_", name, ".csv")
    write.table(df, file=tmpfilename, sep=",", row.names=FALSE, quote=FALSE)
    db_load_from_file(dest, name, tmpfilename, append=append, sep=",", skip=1L)
    file.remove(tmpfilename)
  }
  else {
    db_insert_into(dest$con, name, df)
  }

  db_analyze(dest$con, name)

  tbl(dest, name)
}

#' @export
db_create_table.src_vector <- function(src, table, types, temporary=FALSE, ...)
{
  db_create_table(src$con, table, types, temporary, ...)
}

#' @export
db_create_table.VectorConnection <- function(con, table, types, temporary=FALSE, ...) {
  assert_that(is.string(table), is.character(types))
  if(db_has_table(con, table)) stop("Table name already exists")

  field_names <- escape(ident(names(types)), collapse = NULL, con = con)
  fields <- dplyr:::sql_vector(paste0(field_names, " ", types), parens = TRUE,
                               collapse = ", ", con = con)

  sql <- build_sql("CREATE ", if(temporary) sql("TEMPORARY "), "TABLE ", ident_schema_table(table), " ", fields, con = con)

  #invisible(send_query(con@conn, sql))
  send_query(con@conn, sql)

  if(!db_has_table(con, table)) stop("Could not create table; are the data types specified in Vector-compatible format?")
}

# Currently slow for bulk insertions
db_insert_into.VectorConnection <- function(con, table, values, ...) {
  cols <- lapply(values, escape, collapse = NULL, parens = FALSE, con = con)
  col_mat <- matrix(unlist(cols, use.names = FALSE), nrow = nrow(values))
  coltypes <- unname(db_data_type(con, values))

  col_mat <- apply(col_mat,1, function(x){suppressWarnings(apply(cbind(x,coltypes),1,function(y){
    if(y[1] == "NULL") y[1] = paste0("CAST(",y[1]," AS ",y[2],")")
    y[1]
    })) 
  })

  col_mat <- t(col_mat)
  all_rows <- apply(col_mat, 1, paste0, collapse = ", ")
  block_size = 2000;
  num_blocks = ceiling(length(all_rows)/block_size)

  for(a in 1:num_blocks){
    start = (a-1) * block_size + 1
    end = start + block_size - 1
    end = min(length(all_rows),end)

    rows <- all_rows[start:end]
    last_row <- tail(rows,1)
    last_row <- paste0("SELECT ",last_row)
    formatted_rows <- paste0("SELECT ",rows,"\nUNION ALL")
    formatted_rows[length(formatted_rows)] <- last_row;

    sql <- build_sql(paste0("INSERT INTO ", ident_schema_table(table), "\n", sql(paste(formatted_rows, collapse="\n"))))
    sql <- gsub("''","'",sql)
    sql <- substr(sql,2,nchar(sql)-1)
    send_query(con@conn, sql)
   }
}

#' Saves a tbl object as a view in Vector.
#'
#' If the save is defined to be temporary (non-default behavior), the view will be deleted
#' upon termination of the session.
#' 
#' Note that all views (temporary and permanent) are treatable as tbl objects in Vector.dplyr.
#'
#' @param table The local R-variable name of the tbl_Vector object to be saved as a view in Vector.
#' @param name The name with which to associate the new view in Vector.
#' @param temporary (Default: FALSE) TRUE if the saved view is to be a local temporary one. Note that saving locally will reduce 
#' available parallelism to the native data loader. 
#' @return A new tbl_Vector reference to the saved view.
#' @examples
#' \dontrun{
#' Vector <- src_vector("VectorDSN")
#' table1 <- tbl(Vector,"some_table")
#' table1_modified <- filter(table1,foo > 3)
#' new_view <- db_save_view(table1_modified,name="some_table_filtered")
#' }
#' @export
db_save_view <- function(table, name, temporary = FALSE) {
  v_sql <- build_sql("CREATE ", if (temporary) sql("LOCAL TEMPORARY "),"VIEW ", ident_schema_table(name),
    " AS ", table$query$sql, con = table$src$con)
  send_query(table$src$con@conn, v_sql)
  message(paste0("Created ", ifelse(temporary,"temporary ",""), "view ","`",name,"`."))
  update(tbl(table$src, name), group_by = groups(table))
}

#' @export
db_save_query.VectorConnection <- function(con, sql, name, temporary = FALSE,...){
  if(temporary) warning("Creating temporary tables is not supported. Saving as a permanent table.")
  t_sql <- build_sql("CREATE TABLE ", ident_schema_table(name), " AS ", sql, con = con)
  send_query(con@conn, t_sql)
  name
}

#' @export
db_save_query.src_vector <- function(src, sql, name, temporary = FALSE,...) {
  db_save_query(src$con, sql, name, temporary,...)
}

#' @export
db_list_tables.VectorConnection <- function(con) {
  tbl_query <- "SELECT schema_name,table_name FROM iitables WHERE system_use NOT IN (\'S\')"
  if(con@type=="ODBC") {
    res <- sqlQuery(con@conn,tbl_query)
  }
  else {
    res <- dbGetQuery(con@conn,tbl_query)
  }

  mapply(function(x,y) {
    if(as.character(x) != getOption("dplyr.Vector_default_schema")) {
      y <- paste0('"', as.character(x), '"."', as.character(y), '"')
    }
    as.character(y)
  }, res[[1]], res[[2]])
}

#' @export
db_list_tables.src_vector <- function(src) {
  db_list_tables(src$con)
}

#' @export
db_has_table.src_vector <- function(src, table) {
  db_has_table(src$con, table)
}

#' @export
db_has_table.VectorConnection <- function(con, table) {
  assert_that(is.string(table))

  st <- get_schema_table(table)
  tbl_query <- paste0("SELECT COUNT(*) as N FROM iitables WHERE lower(table_name)=\'", tolower(st$table), "\'")
                      #"\' AND lower(schema_name)=\'", tolower(st$schema),"\'")
  res <- send_query(con@conn, tbl_query, useGetQuery=TRUE)
  res$N > 0
}

#' @export
db_drop_table.src_vector <- function(src, table, force = FALSE, ...) {
  db_drop_table(src$con, table, force, ...)
}

#' @export
db_drop_table.VectorConnection <- function(con, table, force = FALSE, ...) {
  assert_that(is.string(table))

  if(!db_has_table(con, table)) stop("Table does not exist in database.")

  sql <- build_sql("DROP TABLE ", if (force) sql("IF EXISTS "), ident_schema_table(table),
    con = con)
  send_query(con@conn, sql)
}

#' @export
db_drop_view.src_vector <- function(src, view) {
  db_drop_view(src$con, view)
}

#' Like db_drop_table, but for views.
#'
#' @param con dplyr src connection object 
#' @param view The name of the view in DB to drop.
#' @export
db_drop_view <- function(con, view) {
  UseMethod("db_drop_view")
}

#' @method db_drop_view VectorConnection
#' @export
db_drop_view.VectorConnection <- function(con, view) {
  assert_that(is.string(view))

  if(!db_has_table(con, view)) stop("View does not exist in database.")

  sql <- build_sql("DROP VIEW ", ident_schema_table(view),
    con = con)
  send_query(con@conn, sql)
}

#' @export
db_query_fields.VectorConnection <- function(con, sql, addAlias=FALSE, ...){
  assert_that(is.string(sql), is.sql(sql))
  from <- if(is.schema_table(sql)) ident_schema_table(sql)
          else sql

  if(addAlias) from <- paste0("(",from,") AS FOO")

  fields <- paste0("SELECT * FROM ", from, " WHERE 0=1")
  qry <- send_query(con@conn, fields, useGetQuery=TRUE)
  names(qry)
}

#' @export
db_query_rows.VectorConnection <- function(con, sql, ...) {
  assert_that(is.string(sql), is.sql(sql))
  from <- if(is.schema_table(sql)) ident_schema_table(sql)
          else sql_subquery(con, sql, "master")
  rows <- paste0("SELECT count(*) FROM ", from)
  as.integer(send_query(con@conn, rows, useGetQuery=TRUE)[[1]])
}

# Explains queries
#' @export
db_explain.VectorConnection <- function(con, sql, ...) {
  exsql <- build_sql("EXPLAIN ", sql, con = con)
  output <- send_query(con@conn, exsql, useGetQuery=TRUE)
  output <- apply(output,1,function(x){
    if(substring(x,1,1) == "|") x = paste0("\n",x)
    if(x == "") x = "\n"
    x
  })

  graphVizInd <- match("PLAN: BASE QUERY PLAN (GraphViz Format)",output)
  output[1:(graphVizInd-4)]
}

# Used to select UDFs without FROM clauses
#' Like dplyr::select, but allows for the first argument to be a src_vector object
#' for SELECT statements without FROM clauses.
#' @param .arg dplyr tbl OR src_vector connection object 
#' @param ... table columns (i.e., as used in mutate())
#' @param evalNames pre-evaluate the statement to get column names of result (useful for functions that return more than one column)
#' @param collapse collapse query into subquery (DEFAULT is TRUE); FALSE is needed for certain procedures quiring that the procedure name cannot be a part of a subquery
#' @return a tbl_Vector object
#' @examples
#' \dontrun{
#' Vector <- src_vector("VectorDSN")
#' table <- select(Vector,foo=some_fun())
#' table2 <- select(table,some_col_in_table)
#' }
#' @export
select <- function(.arg,...,evalNames=FALSE,collapse=TRUE,transform.UDF=FALSE) {

  if(!is(.arg,"tbl") && !is(.arg,"data.frame")) {
      stopifnot(is(.arg,"src_vector"))
      tbl <- make_tbl(c("Vector", "sql"),
      src = .arg,              # src object
      from = NULL,            # table, join, or raw sql
      select = NULL,          # SELECT: list of symbols
      summarise = FALSE,      #   interpret select as aggreagte functions?
      mutate = FALSE,         #   do select vars include new variables?
      where = NULL,           # WHERE: list of calls
      group_by = NULL,        # GROUP_BY: list of names
      order_by = NULL         # ORDER_BY: list of calls
    )
  
    tbl$query <- query(tbl$src$con, sql(" "), NULL)    

    mutate_(tbl,.dots = lazyeval::lazy_dots(...), .evalNames=evalNames,.collapse=collapse)

  } else if(transform.UDF) {
      mutate_(.arg,.dots = lazyeval::lazy_dots(...), .dropCols=TRUE, .evalNames=evalNames, .collapse=collapse) 
  } else {
    tryCatch(dplyr::select(.arg,...),error=function(e) {
      mutate_(.arg,.dots = lazyeval::lazy_dots(...), .evalNames=evalNames,.collapse=collapse) 
    })
  }

}

#' Like dplyr::mutate, but allows for pre-evaluation to get column names (useful for multi-column returning functions)
#' @param .data dplyr tbl 
#' @param ... table columns (i.e., as used in dplyr::mutate())
#' @param evalNames pre-evaluate the statement to get column names of result (useful for functions that return more than one column)
#' @param collapse collapse query into subquery (DEFAULT is TRUE); FALSE is needed for certain procedures quiring that the procedure name cannot be a part of a subquery
#' @return a tbl_Vector object
#' @export
mutate <- function(.data, ..., evalNames=FALSE, collapse=TRUE) {
  if(is(.data,"tbl_Vector")) {
    mutate_(.data, .dots = lazyeval::lazy_dots(...), .evalNames=evalNames, .collapse=collapse)
  } else {
    dplyr::mutate(.data, ...)
  }
}

#' @export
mutate_.tbl_Vector <- function(.data, ..., .dots, .evalNames = FALSE, .collapse=TRUE, .dropCols=FALSE) {
  dots <- lazyeval::all_dots(.dots, ..., all_named = !.evalNames)
  input <- partial_eval(dots, .data)

  .data$mutate <- TRUE

  if(.evalNames || .dropCols) .data$select <- NULL

  new <- update(.data, select = c(.data$select, input))
 
  if(.evalNames) {
    new_cols <- db_query_fields(new$src$con, new$query$sql, addAlias=TRUE)
    new_cols <- sapply(new_cols, as.name)
    new$select <- new_cols
  }
  
  if(.collapse) {
    collapse(new)
  } else {
    new
  }
}

#' @export
sql_escape_ident.VectorConnection <- function(con, x) {
  sql_quote(x,'"')
}

# Analyze for performance
#' @export
db_analyze.VectorConnection <- function(con, table, ...) {
   assert_that(is.string(table))

   query <- build_sql("SELECT ANALYZE_STATISTICS('", gsub('"','', ident_schema_table(table)), "')")
   send_query(con@conn, query, useGetQuery=TRUE)
}

#' @export
db_create_index.VectorConnection <- function(con, table, columns, name = NULL,
                                             ...) {
  warning("User-created indexes are unsupported")
}

#' @export
db_data_type.VectorConnection <- function(con, fields, ...) {
  vapply(fields, get_data_type, FUN.VALUE=character(1))
}

get_data_type <- function(val, ...) {
            if (is.integer(val)) "INTEGER"
            else if (is.numeric(val)) "DOUBLE PRECISION"
            else "VARCHAR(255)"
}

#' @export
sql_set_op.VectorConnection <- dplyr:::sql_set_op.DBIConnection

# Override allows SELECT without FROM, as well as support for schema tables
#' @export
sql_select.VectorConnection <- function(con, select, from, where = NULL,
                                     group_by = NULL, having = NULL,
                                     order_by = NULL, limit = NULL,
                                     offset = NULL, ...) {

  out <- vector("list", 8)
  names(out) <- c("select", "from", "where", "group_by", "having", "order_by","offset", "limit")

  assert_that(is.character(select), length(select) > 0L)
  out$select <- build_sql("SELECT ", escape(select, collapse = ", ", con = con))
  

  if (length(from) > 0L) { 
    assert_that(is.string(from))
    if(is.schema_table(from)) from <- ident_schema_table(from)
    out$from <- build_sql("FROM ", from, con = con)
  }

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

  if (!is.null(limit) && !is.na(limit)) {
    assert_that(is.integer(limit), length(limit) == 1L)
    out$limit <- build_sql("FETCH FIRST ", limit, " ROWS ONLY ", con = con)
  }

  if (!is.null(offset)) {
    assert_that(is.integer(offset), length(offset) == 1L)
    out$offset <- build_sql("OFFSET ", offset, con = con)
  } else if(!is.null(limit) && !is.na(limit)) {
    out$offset <- build_sql("OFFSET 0", con = con)
  }

  escape(unname(dplyr:::compact(out)), collapse = "\n", parens = FALSE, con = con)
}

#' @export
sql_escape_string.VectorConnection <- dplyr:::sql_escape_string.DBIConnection
#' @export
sql_join.VectorConnection <- dplyr:::sql_join.DBIConnection
#' @export
sql_subquery.VectorConnection <- dplyr:::sql_subquery.DBIConnection  
#' @export
sql_semi_join.VectorConnection <- dplyr:::sql_semi_join.DBIConnection
                          
setGeneric("checkDB", function (con) {
  standardGeneric("checkDB")
})

setMethod("checkDB", "VectorConnection", function(con) {
  if(con@type == "JDBC") out <- .jcall(con@conn@jc,"Z","isValid",as.integer(1))
  else {
    tryCatch({sqlQuery(con@conn, "SELECT FIRST 1 * FROM iitables")
      out <- TRUE},
      error=function(e){
        out <- FALSE
      })  
  }
  out
})

# Lifted from dplyr package -- only change is adding parens argument and relaxing over arguments requirement
over <- function(expr, partition = NULL, order = NULL, frame = NULL, parens = FALSE) {

  if (!is.null(partition)) {
    partition <- build_sql("PARTITION BY ",
      dplyr:::sql_vector(partition, collapse = ", ",parens))
  }
  if (!is.null(order)) {
    order <- build_sql("ORDER BY ", dplyr:::sql_vector(order, collapse = ", ",parens))
  }
  if (!is.null(frame)) {
    if (is.numeric(frame)) frame <- dplyr:::rows(frame[1], frame[2])
    frame <- build_sql("ROWS ", frame)
  }

  over <- dplyr:::sql_vector(dplyr:::compact(list(partition, order, frame)), parens = TRUE)
  build_sql(expr, " OVER ", over)
}

send_query <- function(conn, query, useGetQuery=FALSE, ...) UseMethod("send_query")

send_query.JDBCConnection <- function(conn, query, useGetQuery=FALSE) {
  if(useGetQuery) dbGetQuery(conn,query)
  else dbSendUpdate(conn,query)
}

send_query.vRODBC <- function(conn, query, ...) {
  sqlQuery(conn,query)
}

getSchemas <- function(con) {
  schemasQuery <- "SELECT table_schema,table_name from iitables"
  send_query(con@conn,schemasQuery) 
}


.attemptLoad <- function(depName, ...) {
  if(depName %in% (.packages())) return()
  tryCatch({message(paste0("Attempting to load package `", depName, "` and its dependencies..."))
    suppressPackageStartupMessages(library(depName,character.only=TRUE))
    message("Successfully loaded.")
    }, error = function(e) {
      msg <- switch(depName,
             RJDBC = "Could not load one or more of the required JDBC packages: RJDBC, DBI and rJava. Please install.",
             vRODBC = "Could not load the required vRODBC package. Please download it from GitHub: https://github.com/Vector/DistributedR/tree/master/vRODBC ", 
             HPdata = "Could not load one or more of HPdata and/or Distributed R and their dependencies. Please download: https://github.com/Vector/DistributedR/ " )
      stop(msg)
    })
}
