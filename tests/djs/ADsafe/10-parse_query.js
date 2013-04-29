/*: "tests/djs/ADsafe/__dom.dref" */ "#use";

/*: tyQueryLoc {Arr(Ref(~lSelector))|(packed v)} > lArrPro */ "#define";

var error /*: (message: Str)  -> { FLS } */ = "#extern";

var qx_exec_ = /*: [;L] () / () -> Ref(L) / (L: {Arr(Str)|(and (packed v) (= (len v) 9))} > lArrPro) */ "#extern";

var parse_query = function (textarg, id) /*: (Str, Str) -> Ref(~lQuery) */
{

  // Convert a query string into an array of op/name/value selectors.
  // A query string is a sequence of triples wrapped in brackets; or names,
  // possibly prefixed by # . & > _, or :option, or * or /. A triple is a name,
  // and operator (one of [=, [!=, [*=, [~=, [|=, [$=, or [^=) and a value.

  // If the id parameter is supplied, then the name following # must have the
  // id as a prefix and must match the ADsafe rule for id: being all uppercase
  // letters and digits with one underbar.

  // A name must be all lower case and may contain digits, -, or _.

  var match /*: Ref(lm?) */ = null,           // A match array 
      query /*: Ref  { Arr(Ref(~lSelector))|(packed v)} */ =  [],   // The resulting query array
      //selector  /*: Ref(~lSelector) */ = null;                     //PV: added "null"
      selector /*: Ref(~lSelector) */ = null;                     //PV: added "null"

  var text /*: Str */ = "a";

  //TODO: RegEx
  //,qx = id
  //    ? /^\s*(?:([\*\/])|\[\s*([a-z][0-9a-z_\-]*)\s*(?:([!*~|$\^]?\=)\s*([0-9A-Za-z_\-*%&;.\/:!]+)\s*)?\]|#\s*([A-Z]+_[A-Z0-9]+)|:\s*([a-z]+)|([.&_>\+]?)\s*([a-z][0-9a-z\-]*))\s*/
  //    : /^\s*(?:([\*\/])|\[\s*([a-z][0-9a-z_\-]*)\s*(?:([!*~|$\^]?\=)\s*([0-9A-Za-z_\-*%&;.\/:!]+)\s*)?\]|#\s*([\-A-Za-z0-9_]+)|:\s*([a-z]+)|([.&_>\+]?)\s*([a-z][0-9a-z\-]*))\s*/;

  // Loop over all of the selectors in the text.

  /* ( &selector: Ref(~lSelector)) -> ( &selector: Ref(~lSelector) ) */ 
  /*: () -> ( ) */ 
  do {

    // The qx teases the components of one selector out of the text, ignoring
    // whitespace.

    //          match[0]  the whole selector
    //          match[1]  * /
    //          match[2]  attribute name
    //          match[3]  = != *= ~= |= $= ^=
    //          match[4]  attribute value
    //          match[5]  # id
    //          match[6]  : option
    //          match[7]  . & _ > +
    //          match[8]      name

    //TODO: RegEx
    //match = qx.exec(string_check(text));
    //match = /*: lm {Arr(Str)|(and (packed v) (= (len v) 9))} */ ["0", "1", "2", "3", "4", "5", "6", "7", "8"];
    match = /*: [;lm] */ qx_exec_();

    if (!match) {
      error("ADsafe: Bad query:" + text);
    }

     // Make a selector object and stuff it in the query.

    if (match[1]) {

//    The selector is * or /
      selector = { op: match[1] };
      /*: selector (~lSelector, frzn) */ "#freeze";

    } 
    else if (match[2]) {

      // The selector is in brackets.

      if (match[3]) {
        selector = {
          op: '[' + match[3],
          name: match[2],
          value: match[4]
        };
        /*: selector (~lSelector, frzn) */ "#freeze";

      }    
      else {
        selector = {
          op: '[',
          name: match[2]
        };
        /*: selector (~lSelector, frzn) */ "#freeze";
      }
    } 
    else if (match[5]) {

      // The selector is an id.

      //XXX: SLOW DOWN !!! ~ 8 sec
//      if (query.length > 0 || match[5].length <= id.length ||
//          match[5].slice(0, id.length) !== id) {
//        error("ADsafe: Bad query: " + text);
//      }

      selector = {
        op: '#',
        name: match[5]
      };
      /*: selector (~lSelector, frzn) */ "#freeze";

      // The selector is a colon.

    } 
    else if (match[6]) {
      selector = {
        op: ':' + match[6]
      };
      /*: selector (~lSelector, frzn) */ "#freeze";
      // The selector is one of > + . & _ or a naked tag name
    }
    else {

      selector = {
        op: match[7],
        name: match[8]
      };
      /*: selector (~lSelector, frzn) */ "#freeze";
    }

    //XXX: SLOW DOWN !!! ~ A lot ! 
    // Add the selector to the query.
    //query.push(selector);

    // Remove the selector from the text. If there is more text, have another go.
    //text = text.slice(match[0].length, 0);    //PV: added 2nd argument to slice 

  } while (text);
  
  /*: query (~lQuery, frzn) */ "#freeze";

  return query;
};
