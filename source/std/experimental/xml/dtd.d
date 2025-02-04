/*
*             Copyright Lodovico Giaretta 2016 - .
*  Distributed under the Boost Software License, Version 1.0.
*      (See accompanying file LICENSE_1_0.txt or copy at
*            http://www.boost.org/LICENSE_1_0.txt)
*/

/++
+   Work in progress DTD handling facilities
+/

module std.experimental.xml.dtd;

import std.experimental.xml.interfaces;
import std.typecons : Flag, No;

/+enum DTDCheckerError
{
    DTD_SYNTAX,
}+/
public class DTDException : XMLException {
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, 
            Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, nextInChain);
    }
}
struct DTDCheckerOptions
{
    bool mandatory;
    bool allElementsDeclared;
    bool addDefaultAttributes;
    bool uniqueIDs;
    bool allowOverrides;

    enum DTDCheckerOptions loose =
    {
        mandatory: false,
        allElementsDeclared: false,
        addDefaultAttributes: true,
        uniqueIDs: false,
        allowOverrides: true,
    };
    enum DTDCheckerOptions strict =
    {
        mandatory: true,
        allElementsDeclared: true,
        addDefaultAttributes: true,
        uniqueIDs: true,
        allowOverrides: false,
    };
}

struct DTDChecker(CursorType, DTDCheckerOptions options = DTDCheckerOptions.strict)
    if (isCursor!CursorType)
{
    import std.experimental.xml.faststrings;
    import std.experimental.xml.parser;
    import std.experimental.xml.cursor;

    alias StringType = CursorType.StringType;

    CursorType cursor;
    alias cursor this;

    struct Element
    {
        enum ContentKind
        {
            EMPTY,
            ANY,
            MIXED,
            CHILDREN,
        }

        ContentKind contentKind = ContentKind.ANY;
        union
        {
            StringType[] children;
            StringType childRegex;
        }

        struct Attribute
        {
            enum AttType
            {
                cdata,
                ID,
                IDREF,
                IDREFS,
                ENTITY,
                ENTITIES,
                NMTOKEN,
                NMTOKENS,
                NOTATION,
                ENUMERATION,
            }
            enum DefaultKind
            {
                REQUIRED,
                IMPLIED,
                FIXED,
                DEFAULT,
            }

            AttType type;
            DefaultKind defaultKind;
            StringType defaultValue;
        }

        Attribute[StringType] attrs;
    }

    private Element[StringType] elems;
    private StringType[StringType] entities;
    private StringType rootElem, pubID, sysID;

    //ErrorHandler errorHandler;

    bool enter()
    {
        if (cursor.enter)
        {
            if (cursor.kind == XMLKind.dtdStart)
            {
                import std.experimental.xml.faststrings;

                auto dtd = cursor.content;

                auto start = dtd.fastIndexOfNeither(" \r\n\t");
                if (start == -1)
                {
                    throw new DTDException("DTD Syntax error!");//errorHandler(DTDCheckerError.DTD_SYNTAX);
                    //return true;
                }
                dtd = dtd[start..$];

                auto nameEnd = dtd.fastIndexOfAny(" \r\n\t");
                if (nameEnd == -1)
                    nameEnd = dtd.length;
                rootElem = dtd[0..nameEnd];
                dtd = dtd[nameEnd..$];

                if (!dtd)
                    return true;

                parseSystemID(dtd, pubID, sysID);

                auto bracket = dtd.fastIndexOfNeither(" \r\n\t");
                if (bracket == -1)
                    return true;
                if (dtd[bracket] != '[')
                {
                    throw new DTDException("DTD Syntax error!");
                    //return true;
                }
                auto close = dtd.fastLastIndexOf(']');
                if (dtd[(close+1)..$].fastIndexOfNeither(" \r\n\t") != -1)
                {
                    throw new DTDException("DTD Syntax error!");
                    //return true;
                }
                dtd = dtd[(bracket+1)..close];

                /*auto cur = chooseParser!dtd.cursor((CursorError err) {});
                cur.setSource(dtd);
                if (cur.enter)
                    parseDTD(cur);*/
            }
            return true;
        }
        return false;
    }

    private void parseDTD(T)(ref T cur)
    {
        do
        {
            switch (cur.kind) with (XMLKind)
            {
                case attlistDecl:
                    parseAttlistDecl(cur.content);
                    break;
                case elementDecl:
                    parseElementDecl(cur.content);
                    break;
                case notationDecl:
                    parseNotationDecl(cur.content);
                    break;
                case entityDecl:
                    parseEntityDecl(cur.content);
                    break;
                default:
                    throw new DTDException("DTD Syntax error!");
            }
        }
        while (cur.next);
    }

    private void parseAttlistDecl(StringType decl)
    {
    }

    private void parseElementDecl(StringType decl)
    {
        auto name = parseWord(decl);
        if (!name)
        {
            throw new DTDException("DTD Syntax error!");
            //return;
        }

        auto elem = name in elems;
        if (elem && !options.allowOverrides)
        {
            throw new DTDException("DTD Syntax error!");
            //return;
        }
        if (!elem)
        {
            elems[name] = Element();
        }

        auto copy = decl;
        auto contentType = parseWord(decl);
        if (!contentType)
        {
            throw new DTDException("DTD Syntax error!");
            //return;
        }

        if (contentType.length == 3 && fastEqual(contentType, "ANY"))
        {
            elems[name].contentKind = Element.ContentKind.ANY;
        }
        else if (contentType.length == 5 && fastEqual(contentType,   "EMPTY"))
        {
            elems[name].contentKind = Element.ContentKind.EMPTY;
        }
        else
        {

        }
    }

    private void parseNotationDecl(StringType decl)
    {
    }

    private void parseEntityDecl(StringType decl)
    {
    }

    private StringType parseWord(ref StringType str)
    {
        auto start = str.fastIndexOfNeither(" \r\n\t");
        if (start == -1)
            return [];

        auto end = str[start..$].fastIndexOfAny(" \r\n\t");
        if (end == -1)
            end = str.length - start;

        auto res = str[start..(start+end)];
        str = str[(start+end)..$];
        return res;
    }

    private StringType parseString(ref StringType str)
    {
        auto start = str.fastIndexOfNeither(" \r\n\t");
        if (start == -1)
        {
            throw new DTDException("DTD Syntax error!");
            //return [];
        }

        auto ch = str[start];
        if (ch != '\'' && ch != '"')
        {
            throw new DTDException("DTD Syntax error!");
            //return [];
        }

        auto end = str[(start+1)..$].fastIndexOf(ch);
        if (end == -1)
        {
            throw new DTDException("DTD Syntax error!");
            //return [];
        }

        auto res = str[(start+1)..(start+end+1)];
        str = str[(start+end+2)..$];
        return res;
    }

    private StringType parsePublicID(ref StringType str)
    {
        auto start = str.fastIndexOfNeither(" \r\n\t");
        if (start == -1)
            return [];

        auto end = str[start..$].fastIndexOfAny(" \r\n\t");
        // we find the identifier PUBLIC
        if (end == 6 && "PUBLIC".fastEqual(str[start..(start+end)]))
        {
            str = str[(start+end)..$];
            return parseString(str);
        }
        return [];
    }

    private void parseSystemID(ref StringType str, out StringType pubID, out StringType systemID)
    {
        pubID = parsePublicID(str);
        if (!pubID)
        {
            auto start = str.fastIndexOfNeither(" \r\n\t");
            if (start == -1)
                return;

            auto end = str[start..$].fastIndexOfAny(" \r\n\t");
            // we find the identifier SYSTEM
            if (end == 6 && "SYSTEM".fastEqual(str[start..(start+end)]))
                str = str[(start+end)..$];
            else
                return;
        }
        systemID = parseString(str);
    }
}

auto dtdChecker(DTDCheckerOptions options = DTDCheckerOptions.strict, CursorType)
               (auto ref CursorType cursor)
{
    auto res = DTDChecker!(CursorType, options)();
    res.cursor = cursor;
    return res;
}


unittest
{
    import std.experimental.xml.lexers;
    import std.experimental.xml.parser;
    import std.experimental.xml.cursor;

    auto xml = q{
        <?xml?>
        <!DOCTYPE root PUBLIC "ciaone" "https://qualcosa" [
            <!ELEMENT root ANY>
        ] >
        <root>
        </root>
    };

    auto cursor =
         xml
        .lexer
        .parser
        .cursor
        .dtdChecker;

    cursor.setSource(xml);
    cursor.enter;
    assert(cursor.next);

    assert(cursor.rootElem == "root", cursor.rootElem);
    assert(cursor.pubID == "ciaone");
    assert(cursor.sysID == "https://qualcosa");

    //assert(cursor.elems.length == 1);
    //assert(cursor.elems["root"].contentKind == typeof(cursor).Element.ContentKind.ANY);
}