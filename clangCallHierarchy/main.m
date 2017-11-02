//
//  main.m
//  clangCallHierarchy
//
//  Created by sogou on 27/10/2017.
//  Copyright © 2017 sogou. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <clang-c/Index.h>
#include <stdlib.h>
#include <unistd.h>
#include <ftw.h>
#include <time.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#import <sqlite3.h>


static const char *SQL_DROP_TABLE = "DROP TABLE IF EXISTS oc_references;";
static const char *SQL_CREATE_TABLE = "CREATE TABLE IF NOT EXISTS oc_references (caller TEXT, caller_file TEXT, caller_row INT, caller_col INT, callee TEXT, callee_file TEXT, callee_row INT, callee_col INT);";
static const char *SQL_INSERT_STATEMENT = "INSERT INTO oc_references VALUES('%s', '%s', %d, %d, '%s', '%s', %d, %d);";


sqlite3 *sqlite3DataBase = NULL;

void closeDB() {
    sqlite3_close(sqlite3DataBase);
}

void runQuery(char *query) {
    sqlite3_stmt *compiledStatement;
    int prepareResult = sqlite3_prepare_v2(sqlite3DataBase, query, -1, &compiledStatement, NULL);
    if(prepareResult != SQLITE_OK) {
        fprintf(stderr, "DB error: %s", sqlite3_errmsg(sqlite3DataBase));
        closeDB();
        assert(false);
    }
    
    BOOL execResult = sqlite3_step(compiledStatement);
    if (execResult != SQLITE_DONE) {
        fprintf(stderr, "DB error: %s", sqlite3_errmsg(sqlite3DataBase));
        return;
    }
    sqlite3_finalize(compiledStatement);
}

void openOrCreateDB() {
    char *filePath = "./db.sqlite";
    int openDataBaseResult = sqlite3_open(filePath, &sqlite3DataBase);
    assert(openDataBaseResult == SQLITE_OK);
    char *sql = (char *)SQL_DROP_TABLE;
    runQuery(sql);
    sql = (char *)SQL_CREATE_TABLE;
    runQuery(sql);
}

typedef struct SymbolPosition {
    char *symbol;
    char *file;
    int row;
    int col;
} SymbolPosition;

char *createInsertQueryFor(SymbolPosition caller, SymbolPosition callee) {
    char *statement = (char *)malloc(1000);
    memset(statement, 0, 1000);
    
    sprintf(statement, SQL_INSERT_STATEMENT, caller.symbol, caller.file, caller.row, caller.col, callee.symbol, callee.file, callee.row, callee.col);
    return statement;
}

void destroyInsertQuery(char *statement) {
    free(statement);
}

CXIndex g_clangIndex;
NSArray *g_args;

static void freestring(CXString *str)
{
    clang_disposeString(*str);
}

#define SCOPED_STR(name, value)\
__attribute__((unused))\
__attribute__((cleanup(freestring))) CXString name ## str = value;\
const char *name = clang_getCString(name ## str);

#define NS_STR(name, value) \
SCOPED_STR(name, value) \
NSString *str_##name = [NSString stringWithUTF8String: name];

//SymbolPosition getSymbolPositionInfo(CXCursor cursor) {
//    CXSourceLocation loc = clang_getCursorLocation(cursor);
//    CXFile file;
//    unsigned row, col, offset;
//    clang_getExpansionLocation(loc, &file, &row, &col, &offset);
//    const char *fileName = clang_getCString(clang_getFileName(file));
//    SymbolPosition p = {.file = (char *)fileName, .row = row, .col = col};
//    return p;
//}

static enum CXChildVisitResult
functionCallVisitor(CXCursor cursor, CXCursor parent, CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    if (clang_isInvalid(kind))
        return CXChildVisit_Recurse;
    
    if (kind != CXCursor_ObjCMessageExpr && kind != CXCursor_CallExpr && kind != CXCursor_MemberRef && kind != CXCursor_MemberRefExpr)// && kind != CXCursor_ObjCClassRef && kind != CXCursor_ObjCSuperClassRef)
        return CXChildVisit_Recurse;
    
//    if (kind == CXCursor_MemberRef || kind == CXCursor_MemberRefExpr) {
//        const char *cur = clang_getCString(clang_getCursorUSR(cursor));
//        const char *ref = clang_getCString(clang_getCursorUSR(clang_getCursorReferenced(cursor)));
//        printf("%s (%s)\n", cur, ref);
//    }
    
    CXCursor referenced = clang_getCursorReferenced(cursor);
    if (!clang_isInvalid(referenced.kind)) {
        SCOPED_STR(usr, clang_getCursorUSR(referenced));
        CXSourceLocation loc = clang_getCursorLocation(referenced);
        CXFile file;
        unsigned row, col, offset;
        clang_getExpansionLocation(loc, &file, &row, &col, &offset);
        SCOPED_STR(fileName, clang_getFileName(file));
        SymbolPosition callee = {.file = (char *)fileName, .row = row, .col = col};
        callee.symbol = (char *)usr;
        
        SymbolPosition caller = *(SymbolPosition *)client_data;
        
//        printf("%s -> %s\n", caller.symbol, usr);
        
        char *statement = createInsertQueryFor(caller, callee);
        runQuery(statement);
        destroyInsertQuery(statement);
    }
//    if (strlen(usr) == 0) {
//        CXType receiverType = clang_Cursor_getReceiverType(cursor);
//        char *prefix = receiverType.kind == CXType_ObjCInterface?"+":"-";
//        const char *ownerClass = clang_getCString(clang_getCursorUSR(clang_getCursorSemanticParent((cursor))));
//        const char *selectorName = clang_getCString(clang_getCursorUSR((cursor)));
//        printf("%\t%s[%s %s]", prefix, ownerClass, selectorName);
//    }
//    else {
//    }
//    NSString *usr = [NSString stringWithUTF8String:clang_getCString(clang_getCursorUSR(clang_getCursorReferenced(cursor)))];
//    NSLog(@"\t\t\t%@", usr);
    
    
    //    NS_STR(selName, clang_getCursorDisplayName(cursor));
    //    NSMutableString *functionDesc = [NSMutableString string];
    //    if (kind == CXCursor_ObjCMessageExpr) {
    //        CXType receiverType = clang_Cursor_getReceiverType(cursor);
    //        NSString *prefix = receiverType.kind == CXType_ObjCInterface?@"+":@"-";
    ////        NSString *ownerClassName = [NSString stringWithUTF8String:clang_getCString(clang_getCursorDisplayName(clang_getCursorSemanticParent(clang_getCursorReferenced(cursor))))];
    ////        [functionDesc appendFormat:@"%@[%@ %@]", prefix, ownerClassName, str_selName];
    ////        NSString *usr = [NSString stringWithUTF8String:clang_getCString(clang_getCursorUSR(clang_getCursorSemanticParent(clang_getCursorReferenced(cursor))))];
    //        NSString *usr = [NSString stringWithUTF8String:clang_getCString(clang_getCursorUSR(clang_getCursorReferenced(cursor)))];
    //        [functionDesc appendFormat:@"%@", usr];
    //    }
    //    else if (kind == CXCursor_CallExpr) {
    //        NSString *usr = [NSString stringWithUTF8String:clang_getCString(clang_getCursorUSR(clang_getCursorReferenced(cursor)))];
    //        [functionDesc appendFormat:@"%@", usr];
    ////        [functionDesc appendFormat:@"%@", str_selName];
    //    }
    //
    //    //Print the function description
    //    NSLog(@"\t\t\t%@", functionDesc);
    return CXChildVisit_Recurse;
}

static enum CXChildVisitResult
visitor(CXCursor cursor, CXCursor parent, CXClientData client_data) {
    enum CXCursorKind kind = clang_getCursorKind(cursor);
    //    CXFile tu_file = (CXFile *)client_data;
    //    CXFile in_file, from_file;
    //    unsigned line, column, offset;
    //    CXSourceLocation loc;
    //    CXString tu_spelling, from_spelling;
    //    if (clang_isInvalid(kind))
    //        return CXChildVisit_Recurse;
    if (kind != CXCursor_ObjCImplementationDecl && kind != CXCursor_ObjCCategoryImplDecl)
        return CXChildVisit_Continue;
    
//    NS_STR(classImplName, clang_getCursorDisplayName(cursor));
    
//    unsigned int curLevel  = *(unsigned int*)client_data;
//    unsigned int nextLevel = curLevel + 1;
    
    clang_visitChildrenWithBlock(cursor, ^enum CXChildVisitResult(CXCursor cursor, CXCursor parent) {
        enum CXCursorKind kind = clang_getCursorKind(cursor);
        if (kind != CXCursor_ObjCInstanceMethodDecl && kind != CXCursor_ObjCClassMethodDecl)
            return CXChildVisit_Recurse;
        
        //        NS_STR(funcName, clang_getCursorDisplayName(cursor));
        //        NSString *prefix = kind == CXCursor_ObjCClassMethodDecl?@"+":@"-";
        //        NSLog(@"%@[%@ %@]", prefix, str_classImplName, str_funcName);
//        NS_STR(funcName, clang_getCursorUSR(cursor));
//        NSLog(@"%@", str_funcName);
        
        SCOPED_STR(implUSR, clang_getCursorUSR(cursor));
//        printf("%s\n", implUSR);
        
        CXSourceLocation loc = clang_getCursorLocation(cursor);
        CXFile file;
        unsigned row, col, offset;
        clang_getExpansionLocation(loc, &file, &row, &col, &offset);
        SCOPED_STR(fileName, clang_getFileName(file));
        SymbolPosition p = {.file = (char *)fileName, .row = row, .col = col};
        p.symbol = (char *)implUSR;
        
        int nextLevel = nextLevel;
        clang_visitChildren(cursor, functionCallVisitor, &p);
        return CXChildVisit_Continue;
    });

    return CXChildVisit_Recurse;
}

void handleFile(const char* mainFile) {
    int argc = (int)[g_args count];
    const char *argv[argc];
    int i=0;
    for (NSString *arg in g_args) {
        argv[i++] = [arg UTF8String];
    }
    
    CXTranslationUnit translationUnit;
    enum CXErrorCode errorCode =clang_parseTranslationUnit2FullArgv(g_clangIndex,
                                                                    mainFile, argv, argc, 0,
                                                                    0,
                                                                    CXTranslationUnit_None, &translationUnit);
    if (errorCode == CXError_Success) {
        unsigned int treeLevel = 0;
        clang_visitChildren(clang_getTranslationUnitCursor(translationUnit), visitor, &treeLevel);
    }
    clang_disposeTranslationUnit(translationUnit);
}



int handle_entry(const char *filepath, const struct stat *info,
                const int typeflag, struct FTW *pathinfo)
{
    if (typeflag == FTW_F) {
        if (strstr(filepath, ".m") || strstr(filepath, ".mm") || strstr(filepath, ".cpp")) {
            printf("Processing %s\n", filepath);
            handleFile(filepath);
        }
    }
    return 0;
}


int handle_directory_tree(const char *const dirpath)
{
    int result;
    
    /* Invalid directory path? */
    if (dirpath == NULL || *dirpath == '\0')
        return errno = EINVAL;
    
    result = nftw(dirpath, handle_entry, 20, FTW_PHYS);
    if (result >= 0)
        errno = result;
    
    return errno;
}

void doWork() {
//    clang_toggleCrashRecovery(0);
    g_clangIndex = clang_createIndex(0, 0);
    
    NSString *plistPath = @"./DefaultArguments.plist";
    
    NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
    
    // Load the options required to compile GNUstep apps
    NSError *error = nil;
    g_args = [NSPropertyListSerialization propertyListWithData:plistData
                                                              options:NSPropertyListImmutable
                                                               format:nil
                                                                error:&error];
    assert(error == nil);//@"defaultArgument.plist read error!"
    
    handle_directory_tree("/Users/sogou/bsl/SogouInput/SogouInput_4.9.0_new/");
//    handleFile("/Users/sogou/bsl/SogouInput/SogouInput_4.9.0_new/BaseKeyboard/Controller/KeyboardViewController.m");

}

int main(int argc, const char * argv[]) {
    openOrCreateDB();
    doWork();
    closeDB();
    
    return 0;
}
