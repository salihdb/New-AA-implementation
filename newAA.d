// vim:set ts=4 sw=4 expandtab:
// Developmental version of completely native AA implementation.

version=AAdebug;
version(AAdebug) {
    import std.conv;
    import std.stdio;
}

import core.exception;
import core.memory;

// This is a temporary syntactic sugar hack until we manage to get dmd to
// work with us nicely.
version(unittest)
{
    alias AssociativeArray AA;
}

struct AssociativeArray(Key,Value)
{
private:
    // Convenience template to check if a given type can be compared with Key
    // using ==.
	template keyComparable(L) {
		enum bool keyComparable = is(typeof(Key.init==L.init) == bool);
	}

    // Convenience templates to check if a given type can be either implicitly
    // converted to Key, or can be converted via .idup. This is for supporting
    // assigning char[] keys to X[string], for example.
    template keyIdupCompat(L) {
        static if (__traits(compiles, L.init.idup))
            enum keyIdupCompat = is(typeof(L.init.idup) : Key);
        else
            enum keyIdupCompat = false;
    }
    template keySliceCompat(L) {
        // Issue 7665: allow dynamic array assignment to static array keys.
        static if (is(Key kbase : kbase[N], int N) && is(L lbase : lbase[]))
            enum keySliceCompat = is(lbase : kbase);
        else
            enum keySliceCompat = false;
    }
    template keyCompat(L) {
        enum bool keyCompat = keyComparable!L && (is(L : Key)
                              || keyIdupCompat!L
                              || keySliceCompat!L);
    }

    struct Slot
    {
        Slot   *next;
        hash_t  hash;
        Key     key;
        Value   value;

        // This ctor accepts any key type that can either be implicitly
        // converted to Key, or has an .idup method that returns a type
        // implicitly convertible to Key.
        this(K)(hash_t h, K k, Value v, Slot *_next=null) if (keyCompat!K)
        {
            next = _next;
            hash = h;

            static if (is(K : Key))
                key = k;
            else static if (keyIdupCompat!K)
                key = k.idup;
            else static if (keySliceCompat!K && is(Key b : b[N], int N))
            {
                assert(k.length==N, "Tried to set key with wrong size in "
                                    "associative array with fixed-size key");
                key = k[0..N];
            }
            else
                static assert(false);

            value = v;
        }
    }

    struct Impl
    {
        Slot*[]  slots;
        size_t   nodes;

        // Prevent extra allocations for very small AA's.
        Slot*[4] binit;
    }

    // Range interface
    struct Range
    {
        Slot*[] slots;
        Slot* curslot;

        this(Impl *i) pure nothrow @safe
        {
            if (i !is null)
            {
                slots = i.slots;
                nextSlot();
            }
        }

        void nextSlot() pure nothrow @safe
        {
            while (slots.length > 0)
            {
                if (slots[0] !is null)
                {
                    curslot = slots[0];
                    break;
                }
                slots = slots[1..$];
            }
        }

        @property bool empty() pure const nothrow @safe
        {
            return curslot is null;
        }

        @property ref inout(Slot) front() inout pure const nothrow @safe
        {
            assert(curslot);
            return *curslot;
        }

        void popFront() pure @safe nothrow
        {
            assert(curslot);
            curslot = curslot.next;
            if (curslot is null)
            {
                slots = slots[1..$];
                nextSlot();
            }
        }
    }

    // Reference semantics
    Impl *impl;

    // Preset prime hash sizes for auto-rehashing.
    // FIXME: this shouldn't be duplicated for every template instance.
    static immutable size_t[] prime_list = [
                   31UL,
                   97UL,            389UL,
                1_543UL,          6_151UL,
               24_593UL,         98_317UL,
              393_241UL,      1_572_869UL,
            6_291_469UL,     25_165_843UL,
          100_663_319UL,    402_653_189UL,
        1_610_612_741UL,  4_294_967_291UL,
    //  8_589_934_513UL, 17_179_869_143UL
    ];

    static size_t findAllocSize(size_t size) pure nothrow @safe
    {
        size_t i;
        for (i=0; i < prime_list.length; i++)
        {
            if (size <= prime_list[i])
                break;
        }
        return prime_list[i];
    }

    static Slot*[] alloc(size_t len) @trusted
    {
        auto slots = new Slot*[len];
        GC.setAttr(&slots, GC.BlkAttr.NO_INTERIOR);
        return slots;
    }

    inout(Slot) *findSlot(K)(in K key) inout /*pure nothrow*/ @trusted
        if (keyComparable!K)
    {
        if (!impl)
            return null;

        auto keyhash = typeid(key).getHash(&key);
        auto i = keyhash % impl.slots.length;
        inout(Slot)* slot = impl.slots[i];
        while (slot) {
            if (slot.hash == keyhash && typeid(key).equals(&key, &slot.key))
            {
                return slot;
            }
            slot = slot.next;
        }
        return slot;
    }

public:
    static typeof(this) fromLiteral(Key[] keys, Value[] values) @safe
    in { assert(keys.length == values.length); }
    body
    {
        typeof(this) aa;
        aa.impl = new Impl();
        aa.impl.slots = alloc(findAllocSize(keys.length));

        foreach (i; 0 .. keys.length)
        {
            aa[keys[i]] = values[i];
        }
        return aa;
    }

    hash_t toHash() /*nothrow pure*/ const @trusted
    {
        // AA hashes must:
        // (1) depend solely on key/value pairs stored in it, regardless of the
        //     size of the hashtable and/or any other implementation-specific
        //     states;
        // (2) be independent of the order of key/value pairs.
        //
        // So we compute a hash value for each key/value pair by combining
        // their respective hash values, and use a commutative operation
        // (addition) to combine these hash values into an overall hash for the
        // entire AA.
        hash_t h = 0;
        if (!impl)
            return h;

        foreach (const(Slot)* s; impl.slots)
        {
            while (s)
            {
                // NOTE: use a non-commutative operation (hashOf) to combine
                // the key and value hashes to minimize collisions when dealing
                // with things like int[int].
                import rt.util.hash;

                hash_t[2] pairhash;
                pairhash[0] = s.hash;
                pairhash[1] = typeid(Value).getHash(&s.value);

                h += hashOf(pairhash.ptr, pairhash.length * hash_t.sizeof);

                s = s.next;
            }
        }
        return h;
    }

    @property size_t length() nothrow pure const @safe
    {
        return impl ? impl.nodes : 0;
    }

    Value get(K)(in K key, lazy Value defaultValue) /*pure nothrow*/ const @safe
        if (keyComparable!K)
    {
        auto s = findSlot(key);
        return (s is null) ? defaultValue : s.value;
    }

    Value *opBinaryRight(string op, K)(in K key) /*pure*/ @trusted
        if (op=="in" && keyComparable!K)
    {
        auto slot = findSlot(key);
        return (slot) ? &slot.value : null;
    }

    Value opIndex(K)(in K key, string file=__FILE__, size_t line=__LINE__)
        @safe /*pure*/
        if (keyComparable!K)
    {
        Value *valp = opBinaryRight!"in"(key);
        if (valp is null)
            throw new RangeError(file, line);

        return *valp;
    }

    void opIndexAssign(K)(Value value, K key) @trusted /*pure nothrow*/
        // Why isn't getHash() pure?!
        if (keyCompat!K)
    {
        if (!impl)
        {
            impl = new Impl();
            impl.slots = impl.binit;
        }

        auto keyhash = typeid(key).getHash(&key);
        auto i = keyhash % impl.slots.length;
        Slot *slot = impl.slots[i];

        if (slot is null)
        {
            impl.slots[i] = new Slot(keyhash, key, value);
        }
        else
        {
            for(;;) {
                if (slot.hash==keyhash && typeid(key).equals(&key, &slot.key))
                {
                    slot.value = value;
                    return;
                }
                else if (!slot.next)
                {
                    slot.next = new Slot(keyhash, key, value);
                    break;
                }

                slot = slot.next;
            }
        }

        if (++impl.nodes > 4*impl.slots.length)
        {
            this.rehash;
        }
    }

    bool remove(K)(in K key) /*pure nothrow*/ @trusted
        if (keyCompat!K)
    {
        if (!impl) return false;

        auto keyhash = typeid(key).getHash(&key);
        size_t i = keyhash % impl.slots.length;
        auto slot = impl.slots[i];
        if (!slot)
            return false;

        if (slot.hash == keyhash && slot.key == key)
        {
            impl.slots[i] = slot.next;
            impl.nodes--;
            return true;
        }

        while (slot.next)
        {
            if (slot.next.hash == keyhash && slot.next.key == key)
            {
                slot.next = slot.next.next;
                impl.nodes--;
                return true;
            }
            slot = slot.next;
        }

        return false;
    }

    int opApply(scope int delegate(ref Value) dg)
    {
        if (impl is null)
            return 0;

        foreach (Slot *slot; impl.slots)
        {
            while (slot)
            {
                auto result = dg(slot.value);
                if (result)
                    return result;

                slot = slot.next;
            }
        }
        return 0;
    }

    int opApply(scope int delegate(ref Key, ref Value) dg)
    {
        if (impl is null)
            return 0;

        foreach (Slot *slot; impl.slots)
        {
            while (slot)
            {
                auto result = dg(slot.key, slot.value);
                if (result)
                    return result;

                slot = slot.next;
            }
        }
        return 0;
    }

    bool opEquals(inout typeof(this) that) inout nothrow pure @safe
    {
        if (impl is that.impl)
            return true;

        if (impl is null || that.impl is null)
            return false;

        if (impl.nodes != that.impl.nodes)
            return false;

        foreach (inout(Slot)* slot; impl.slots)
        {
            while (slot)
            {
                inout(Slot)* s = that.impl.slots[slot.hash % that.impl.slots.length];

                // To be equal, it is enough for one of the target slots to
                // match the current entry.
                while (s)
                {
                    if (slot.key == s.key && slot.value == s.value)
                        break;
                    s = s.next;
                }

                // No match found at all; give up.
                if (!s) return false;

                slot = slot.next;
            }
        }
        return true;
    }

    @property inout(Key)[] keys() inout @trusted
    {
        inout(Key)[] k;
        if (impl !is null)
        {
            // Preallocate output array for efficiency
            k.reserve(impl.nodes);
            foreach (inout(Slot) *slot; impl.slots)
            {
                while (slot)
                {
                    k ~= slot.key;
                    slot = slot.next;
                }
            }
        }
        return k;
    }

    @property inout(Value)[] values() inout @trusted
    {
        inout(Value)[] v;
        if (impl !is null)
        {
            // Preallocate output array for efficiency
            v.reserve(impl.nodes);
            foreach (inout(Slot) *slot; impl.slots)
            {
                while (slot)
                {
                    v ~= slot.value;
                    slot = slot.next;
                }
            }
        }
        return v;
    }

    @property typeof(this) rehash() @safe
    {
        if (impl is null) return this;

        size_t newlen = findAllocSize(impl.nodes);
        Slot*[] newslots = alloc(newlen);

        foreach (slot; impl.slots)
        {
            while (slot)
            {
                auto next = slot.next;

                // Transplant slot into new hashtable.
                const j = slot.hash % newlen;
                slot.next = newslots[j];
                newslots[j] = slot;

                slot = next;
            }
        }

        // Remove references to slots in old hash table.
        if (impl.slots.ptr == impl.binit.ptr)
            impl.binit[] = null;
        else
            delete impl.slots;

        impl.slots = newslots;

        return this;
    }

    @property auto dup() const /*nothrow pure*/ @safe
    {
        AssociativeArray!(Key,Value) result;
        if (impl !is null)
        {
            result.impl = new Impl();
            result.impl.slots = alloc(findAllocSize(impl.nodes));

            foreach (const(Slot)* slot; impl.slots)
            {
                while (slot)
                {
                    size_t i = slot.hash % result.impl.slots.length;
                    Slot *s = result.impl.slots[i];

                    // FIXME: maybe do shallow copy if value type is immutable?
                    result.impl.slots[i] = new Slot(slot.hash, slot.key,
                                                    slot.value,
                                                    result.impl.slots[i]);
                    result.impl.nodes++;
                    slot = slot.next;
                }
            }
        }
        return result;
    }

    @property auto byKey() pure nothrow @safe
    {
        static struct KeyRange
        {
            Range state;

            this(Impl *p) pure nothrow @safe
            {
                state = Range(p);
            }

            @property ref Key front() pure nothrow @safe
            {
                return state.front.key;
            }

            alias state this;
        }

        return KeyRange(impl);
    }

    @property auto byValue() pure nothrow @safe
    {
        static struct ValueRange
        {
            Range state;

            this(Impl *p) pure nothrow @safe
            {
                state = Range(p);
            }

            @property ref Value front() pure nothrow @safe
            {
                return state.front.value;
            }

            alias state this;
        }

        return ValueRange(impl);
    }
}

// Test reference semantics
unittest {
    AA!(string,int) aa, bb;
    aa["abc"] = 123;
    bb = aa;
    assert(aa.impl is bb.impl);

    aa["def"] = 456;
    assert(bb["def"] == 456);

    // TBD: should the case where aa is empty when it is assigned to bb work as
    // well?
}

// Check consistency with specs
unittest {
    AA!(string,int) aa;
    assert(aa.sizeof==4 || aa.sizeof==8);
    assert(aa.length==0);

    aa["abc"] = 10;
    assert(aa.length==1);
    aa["def"] = 20;
    assert(aa.length==2);
    aa["ghi"] = 30;
    assert(aa.length==3);
    aa.remove("def");
    assert(aa.length==2);
}

// Test .get
unittest {
    AA!(dstring,int) aa;
    aa["mykey"d] = 10;

    assert(aa.get("mykey"d, 99) == 10);
    assert(aa.get("yourkey"d, 99) == 99);
}

// Test opBinaryRight!"in"
unittest {
    AA!(wstring,bool) aa;
    aa["abc"w] = true;
    aa["def"w] = false;

    assert(("abc"w in aa) !is null);
    assert(("xyz"w in aa) is null);
}

// Test opIndexAssign and opIndex
unittest {
    AA!(char,char) aa;
    aa['x'] = 'y';
    aa['y'] = 'z';
    assert(aa[aa['x']] == 'z');
}

// Test opApply.
unittest {
    AA!(int,int) aa;
    aa[10] = 5;
    aa[20] = 17;
    aa[30] = 39;

    int valsum = 0;
    foreach (v; aa) {
        valsum += v;
    }
    assert(valsum == 5+17+39);

    int keysum = 0;
    valsum = 0;
    foreach (k,v; aa) {
        keysum += k;
        valsum += v;
    }
    assert(keysum == 10+20+30);
    assert(valsum == 5+17+39);
}

// Test opEquals and rehash
unittest {
    immutable int[] key1 = [1,2,3];
    immutable int[] key2 = [4,5,6];
    immutable int[] key3 = [1,3,5];
    AA!(immutable int[], char) aa, bb;
    aa[key1] = '1';
    aa[key2] = '2';
    aa[key3] = '3';
    bb[key3] = '3';
    bb[key2] = '2';
    bb[key1] = '1';

    assert(aa==bb);

    // .rehash should not invalidate equality
    bb.rehash;
    assert(aa==bb);
    assert(bb==aa);
}

// Test .keys and .values
unittest {
    AA!(char,int) aa;
    aa['a'] = 1;
    aa['b'] = 2;
    aa['c'] = 3;

    assert(aa.keys.sort == ['a', 'b', 'c']);
    assert(aa.values.sort == [1,2,3]);
}

// Test .rehash
unittest {
    AA!(int,int) aa;
    foreach (i; 0 .. 99) {
        aa[i*10] = i^^2;
    }
    aa.rehash;
    foreach (i; 0 .. 99) {
        assert(aa[i*10] == i^^2);
    }
}

// Test .byKey and .byValue
unittest {
    AA!(int,string) aa;
    aa[100] = "a";
    aa[200] = "aa";
    aa[300] = "aaaa";
    int sum = 0;
    foreach (k; aa.byKey) {
        sum += k;
    }
    assert(sum == 600);

    string x;
    foreach(v; aa.byValue) {
        x ~= v;
    }
    assert(x == "aaaaaaa");
}

// Test implicit conversion (feature requested by Andrei)
unittest {
    AA!(wstring,int) aa;
    wchar[] key = "abc"w.dup;
    aa[key] = 123;

    assert(aa["abc"w] == 123);

    const wchar[] key2 = "abc"w;
    assert(aa[key2] is aa["abc"w]);

    assert(*(key in aa) == 123);
    assert(*(key2 in aa) == 123);
    assert(aa.get(key2, 999) == 123);
}

// Test .remove
unittest {
    const int[] key1 = [1,2,3];
    const int[] key2 = [2,3,1];
    const int[] key3 = [3,1,2];
    const int[] key4 = [1,3,2];

    AA!(const int[],string) aa;
    aa[key1] = "abc";
    aa[key2] = "def";
    aa[key3] = "ghi";

    assert((key1 in aa) !is null);
    assert((key2 in aa) !is null);
    assert((key3 in aa) !is null);

    assert(aa.remove(key2));

    assert((key1 in aa) !is null);
    assert((key2 in aa) is null);
    assert((key3 in aa) !is null);

    assert(!aa.remove(key4));

    assert((key1 in aa) !is null);
    assert((key2 in aa) is null);
    assert((key3 in aa) !is null);
}

// Test .toHash
unittest {
    AA!(int,int) aa1, aa2, aa3;

    aa1[1] = 2;
    aa1[2] = 1;

    aa2[1] = 1;
    aa2[2] = 2;

    aa3[2] = 1;
    aa3[1] = 2;
    aa3.rehash;     // make aa3 binary-different from aa1

    assert(aa1.toHash() != aa2.toHash());
    assert(aa1.toHash() == aa3.toHash());

    // Issue 3824
    AA!(const AA!(int,int), string) meta;
    meta[aa1] = "abc";
    assert(meta[aa3] == "abc");

    meta[aa2] = "def";
    assert(meta[aa1] == "abc"); // ensure no overwrite
    assert(meta[aa2] == "def");

    assert(meta.dup == meta);
}

// Test AA literals API
unittest {
    auto aa = AA!(string,int).fromLiteral(
        ["abc", "def", "ghi"],
        [ 123,   456,   789 ]
    );

    AA!(string,int) bb;
    bb["abc"] = 123;
    bb["def"] = 456;
    bb["ghi"] = 789;

    assert(aa==bb);
}

// Test .dup with a large AA
unittest {
    AA!(int,short) aa;
    foreach (short i; 0..100)
        aa[i*100] = i;

    assert(aa.dup == aa);
}

// Test non-const key type (by Andrei's request)
unittest {
    AA!(int,bool) aa;
    aa[123] = true;
    aa[321] = false;

    const int i = 123;
    assert(aa[i] == true);

    immutable int j = 321;
    assert(aa[j] == false);
}

// Issues 7512 & 7704
unittest {
    AA!(dstring,int) aa;
    aa["abc"d] = 123;
    aa["def"d] = 456;
    aa["ghi"d] = 789;

    foreach (k, v; aa) {
        assert(aa[k] == v);
    }
}

// Issue 7632
unittest {
    AA!(int,int) aa;
    foreach (idx; 0 .. 10) {
        aa[idx] = idx*2;
    }

    int[] z;
    foreach(v; aa.byValue) z ~= v;
    assert(z.sort == aa.values.sort);
}

// Issue 6210
unittest {
    AA!(string,int) aa;
    aa["h"] = 1;
    assert(aa == aa.dup);
}

// Issue 7665
unittest {
    char[] key1 = "abcd".dup;
    AA!(char[4],int) aa;
    aa[key1] = 123;
}

// Issue 5685
unittest {
    int[2] foo = [1,2];
    AA!(int[2],string) aa;
    aa[foo] = "";
    assert(foo in aa);
    //FIXME: this needs to work
    //assert([1,2] in aa);
}

// For development only. (Should this be made available for druntime
// debugging?)
version(AAdebug) {
    void __rawAAdump(K,V)(AssociativeArray!(K,V) aa)
    {
        writefln("Hash at %x (%d entries):",
                 aa.impl, aa.impl is null ? -1: aa.impl.nodes);
        if (aa.impl !is null) {
            foreach(slot; aa.impl.slots) {
                while (slot) {
                    writefln("\tSlot %x:", cast(void*)slot);
                    writefln("\t\tHash:  %x", slot.hash);
                    writeln("\t\tKey:   ", slot.key);
                    writeln("\t\tValue: ", slot.value);

                    slot = slot.next;
                }
            }
        }
        writeln("End");
    }
}
