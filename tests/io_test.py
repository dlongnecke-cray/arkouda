import glob
import os
import shutil
import tempfile
from typing import List, Mapping, Union

import h5py
import numpy as np
import pytest
from base_test import ArkoudaTest
from context import arkouda as ak

from arkouda import io_util

"""
Tests writing Arkouda pdarrays to and reading from files
"""


class IOTest(ArkoudaTest):
    @classmethod
    def setUpClass(cls):
        super(IOTest, cls).setUpClass()
        IOTest.io_test_dir = "{}/io_test".format(os.getcwd())
        io_util.get_directory(IOTest.io_test_dir)

    def setUp(self):
        ArkoudaTest.setUp(self)
        self.int_tens_pdarray = ak.array(np.random.randint(-100, 100, 1000))
        self.int_tens_ndarray = self.int_tens_pdarray.to_ndarray()
        self.int_tens_ndarray.sort()
        self.int_tens_pdarray_dupe = ak.array(np.random.randint(-100, 100, 1000))

        self.int_hundreds_pdarray = ak.array(np.random.randint(-1000, 1000, 1000))
        self.int_hundreds_ndarray = self.int_hundreds_pdarray.to_ndarray()
        self.int_hundreds_ndarray.sort()
        self.int_hundreds_pdarray_dupe = ak.array(np.random.randint(-1000, 1000, 1000))

        self.float_pdarray = ak.array(np.random.uniform(-100, 100, 1000))
        self.float_ndarray = self.float_pdarray.to_ndarray()
        self.float_ndarray.sort()
        self.float_pdarray_dupe = ak.array(np.random.uniform(-100, 100, 1000))

        self.bool_pdarray = ak.randint(0, 1, 1000, dtype=ak.bool)
        self.bool_pdarray_dupe = ak.randint(0, 1, 1000, dtype=ak.bool)

        self.dict_columns = {
            "int_tens_pdarray": self.int_tens_pdarray,
            "int_hundreds_pdarray": self.int_hundreds_pdarray,
            "float_pdarray": self.float_pdarray,
            "bool_pdarray": self.bool_pdarray,
        }

        self.dict_columns_dupe = {
            "int_tens_pdarray": self.int_tens_pdarray_dupe,
            "int_hundreds_pdarray": self.int_hundreds_pdarray_dupe,
            "float_pdarray": self.float_pdarray_dupe,
            "bool_pdarray": self.bool_pdarray_dupe,
        }

        self.dict_single_column = {"int_tens_pdarray": self.int_tens_pdarray}

        self.list_columns = [
            self.int_tens_pdarray,
            self.int_hundreds_pdarray,
            self.float_pdarray,
            self.bool_pdarray,
        ]

        self.names = ["int_tens_pdarray", "int_hundreds_pdarray", "float_pdarray", "bool_pdarray"]

        with open("{}/not-a-file_LOCALE0000".format(IOTest.io_test_dir), "w"):
            pass

    def _create_file(
        self, prefix_path: str, columns: Union[Mapping[str, ak.array]], names: List[str] = None
    ) -> None:
        """
        Creates an hdf5 file with dataset(s) from the specified columns and path prefix
        via the ak.save_all method. If columns is a List, then the names list is used
        to create the datasets

        :return: None
        :raise: ValueError if the names list is None when columns is a list
        """
        if isinstance(columns, dict):
            ak.to_hdf(columns=columns, prefix_path=prefix_path)
        else:
            if not names:
                raise ValueError("the names list must be not None if columns is a list")
            ak.to_hdf(columns=columns, prefix_path=prefix_path, names=names)

    def testSaveAllLoadAllWithDict(self):

        """
        Creates 2..n files from an input columns dict depending upon the number of
        arkouda_server locales, retrieves all datasets and correspoding pdarrays,
        and confirms they match inputs

        :return: None
        :raise: AssertionError if the input and returned datasets and pdarrays don't match
        """
        self._create_file(
            columns=self.dict_columns, prefix_path="{}/iotest_dict".format(IOTest.io_test_dir)
        )
        retrieved_columns = ak.load_all("{}/iotest_dict".format(IOTest.io_test_dir))

        itp = self.dict_columns["int_tens_pdarray"].to_ndarray()
        ritp = retrieved_columns["int_tens_pdarray"].to_ndarray()
        itp.sort()
        ritp.sort()
        ihp = self.dict_columns["int_hundreds_pdarray"].to_ndarray()
        rihp = retrieved_columns["int_hundreds_pdarray"].to_ndarray()
        ihp.sort()
        rihp.sort()
        ifp = self.dict_columns["float_pdarray"].to_ndarray()
        rifp = retrieved_columns["float_pdarray"].to_ndarray()
        ifp.sort()
        rifp.sort()

        self.assertEqual(4, len(retrieved_columns))
        self.assertListEqual(itp.tolist(), ritp.tolist())
        self.assertListEqual(ihp.tolist(), rihp.tolist())
        self.assertListEqual(ifp.tolist(), rifp.tolist())
        self.assertEqual(len(self.dict_columns["bool_pdarray"]), len(retrieved_columns["bool_pdarray"]))
        self.assertEqual(4, len(ak.get_datasets("{}/iotest_dict_LOCALE0000".format(IOTest.io_test_dir))))

    def testSaveAllLoadAllWithList(self):
        """
        Creates 2..n files from an input columns and names list depending upon the number of
        arkouda_server locales, retrieves all datasets and correspoding pdarrays, and confirms
        they match inputs

        :return: None
        :raise: AssertionError if the input and returned datasets and pdarrays don't match
        """
        self._create_file(
            columns=self.list_columns,
            prefix_path="{}/iotest_list".format(IOTest.io_test_dir),
            names=self.names,
        )
        retrieved_columns = ak.load_all(path_prefix="{}/iotest_list".format(IOTest.io_test_dir))

        itp = self.list_columns[0].to_ndarray()
        itp.sort()
        ritp = retrieved_columns["int_tens_pdarray"].to_ndarray()
        ritp.sort()
        ihp = self.list_columns[1].to_ndarray()
        ihp.sort()
        rihp = retrieved_columns["int_hundreds_pdarray"].to_ndarray()
        rihp.sort()
        fp = self.list_columns[2].to_ndarray()
        fp.sort()
        rfp = retrieved_columns["float_pdarray"].to_ndarray()
        rfp.sort()

        self.assertEqual(4, len(retrieved_columns))
        self.assertListEqual(itp.tolist(), ritp.tolist())
        self.assertListEqual(ihp.tolist(), rihp.tolist())
        self.assertListEqual(fp.tolist(), rfp.tolist())
        self.assertEqual(len(self.list_columns[3]), len(retrieved_columns["bool_pdarray"]))
        self.assertEqual(4, len(ak.get_datasets("{}/iotest_list_LOCALE0000".format(IOTest.io_test_dir))))

    def testLsHdf(self):
        """
        Creates 1..n files depending upon the number of arkouda_server locales, invokes the
        ls method on an explicit file name reads the files and confirms the expected
        message was returned.

        :return: None
        :raise: AssertionError if the h5ls output does not match expected value
        """
        self._create_file(
            columns=self.dict_single_column,
            prefix_path="{}/iotest_single_column".format(IOTest.io_test_dir),
        )
        message = ak.ls("{}/iotest_single_column_LOCALE0000".format(IOTest.io_test_dir))
        self.assertIn("int_tens_pdarray", message)

        with self.assertRaises(RuntimeError):
            ak.ls("{}/not-a-file_LOCALE0000".format(IOTest.io_test_dir))

    def testLsHdfEmpty(self):
        # Test filename empty/whitespace-only condition
        with self.assertRaises(ValueError):
            ak.ls("")

        with self.assertRaises(ValueError):
            ak.ls("   ")

        with self.assertRaises(ValueError):
            ak.ls(" \n\r\t  ")

    def testReadHdf(self):
        """
        Creates 2..n files depending upon the number of arkouda_server locales, reads the files
        with an explicit list of file names to the read_all method, and confirms the datasets
        and embedded pdarrays match the input dataset and pdarrays

        :return: None
        :raise: AssertionError if the input and returned datasets don't match
        """
        self._create_file(
            columns=self.dict_columns, prefix_path="{}/iotest_dict_columns".format(IOTest.io_test_dir)
        )

        # test with read_hdf
        dataset = ak.read_hdf(filenames=["{}/iotest_dict_columns_LOCALE0000".format(IOTest.io_test_dir)])
        self.assertEqual(4, len(list(dataset.keys())))

        # test with generic read function
        dataset = ak.read(filenames=["{}/iotest_dict_columns_LOCALE0000".format(IOTest.io_test_dir)])
        self.assertEqual(4, len(list(dataset.keys())))

    def testReadHdfWithGlob(self):
        """
        Creates 2..n files depending upon the number of arkouda_server locales with two
        files each containing different-named datasets with the same pdarrays, reads the files
        with the glob feature of the read_all method, and confirms the datasets and embedded
        pdarrays match the input dataset and pdarrays

        :return: None
        :raise: AssertionError if the input and returned datasets don't match
        """
        self._create_file(
            columns=self.dict_columns, prefix_path="{}/iotest_dict_columns".format(IOTest.io_test_dir)
        )

        retrieved_columns = ak.read_hdf(filenames="{}/iotest_dict_columns*".format(IOTest.io_test_dir))

        itp = self.list_columns[0].to_ndarray()
        itp.sort()
        ritp = retrieved_columns["int_tens_pdarray"].to_ndarray()
        ritp.sort()
        ihp = self.list_columns[1].to_ndarray()
        ihp.sort()
        rihp = retrieved_columns["int_hundreds_pdarray"].to_ndarray()
        rihp.sort()
        fp = self.list_columns[2].to_ndarray()
        fp.sort()
        rfp = retrieved_columns["float_pdarray"].to_ndarray()
        rfp.sort()

        self.assertEqual(4, len(list(retrieved_columns.keys())))
        self.assertListEqual(itp.tolist(), ritp.tolist())
        self.assertListEqual(ihp.tolist(), rihp.tolist())
        self.assertListEqual(fp.tolist(), rfp.tolist())
        self.assertEqual(len(self.bool_pdarray), len(retrieved_columns["bool_pdarray"]))

    def testReadHdfWithErrorAndWarn(self):
        self._create_file(
            columns=self.dict_single_column, prefix_path=f"{IOTest.io_test_dir}/iotest_single_column"
        )
        self._create_file(
            columns=self.dict_single_column,
            prefix_path=f"{IOTest.io_test_dir}/iotest_single_column_dupe",
        )

        # Make sure we can read ok
        dataset = ak.read_hdf(
            filenames=[
                f"{IOTest.io_test_dir}/iotest_single_column_LOCALE0000",
                f"{IOTest.io_test_dir}/iotest_single_column_dupe_LOCALE0000",
            ]
        )
        self.assertIsNotNone(dataset, "Expected dataset to be populated")

        # Change the name of the first file we try to raise an error due to file missing.
        with self.assertRaises(RuntimeError):
            dataset = ak.read_hdf(
                filenames=[
                    f"{IOTest.io_test_dir}/iotest_MISSING_single_column_LOCALE0000",
                    f"{IOTest.io_test_dir}/iotest_single_column_dupe_LOCALE0000",
                ]
            )

        # Run the same test with missing file, but this time with the warning flag for read_all
        with pytest.warns(RuntimeWarning, match=r"There were .* errors reading files on the server.*"):
            dataset = ak.read_hdf(
                filenames=[
                    f"{IOTest.io_test_dir}/iotest_MISSING_single_column_LOCALE0000",
                    f"{IOTest.io_test_dir}/iotest_single_column_dupe_LOCALE0000",
                ],
                strict_types=False,
                allow_errors=True,
            )
        self.assertIsNotNone(dataset, "Expected dataset to be populated")

    def testLoad(self):
        """
        Creates 1..n files depending upon the number of arkouda_server locales with three columns
        AKA datasets, loads each corresponding dataset and confirms each corresponding pdarray
        equals the input pdarray.

        :return: None
        :raise: AssertionError if the input and returned datasets (pdarrays) don't match
        """
        self._create_file(
            columns=self.dict_columns, prefix_path="{}/iotest_dict_columns".format(IOTest.io_test_dir)
        )
        result_array_tens = ak.load(
            path_prefix="{}/iotest_dict_columns".format(IOTest.io_test_dir), dataset="int_tens_pdarray"
        )
        result_array_hundreds = ak.load(
            path_prefix="{}/iotest_dict_columns".format(IOTest.io_test_dir),
            dataset="int_hundreds_pdarray",
        )
        result_array_floats = ak.load(
            path_prefix="{}/iotest_dict_columns".format(IOTest.io_test_dir), dataset="float_pdarray"
        )
        result_array_bools = ak.load(
            path_prefix="{}/iotest_dict_columns".format(IOTest.io_test_dir), dataset="bool_pdarray"
        )

        ratens = result_array_tens.to_ndarray()
        ratens.sort()

        rahundreds = result_array_hundreds.to_ndarray()
        rahundreds.sort()

        rafloats = result_array_floats.to_ndarray()
        rafloats.sort()

        self.assertListEqual(self.int_tens_ndarray.tolist(), ratens.tolist())
        self.assertListEqual(self.int_hundreds_ndarray.tolist(), rahundreds.tolist())
        self.assertListEqual(self.float_ndarray.tolist(), rafloats.tolist())
        self.assertEqual(len(self.bool_pdarray), len(result_array_bools))

        # test load_all with file_format parameter usage
        ak.to_parquet(
            columns=self.dict_columns,
            prefix_path="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
        )
        result_array_tens = ak.load(
            path_prefix="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
            dataset="int_tens_pdarray",
            file_format="Parquet",
        )
        result_array_hundreds = ak.load(
            path_prefix="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
            dataset="int_hundreds_pdarray",
            file_format="Parquet",
        )
        result_array_floats = ak.load(
            path_prefix="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
            dataset="float_pdarray",
            file_format="Parquet",
        )
        result_array_bools = ak.load(
            path_prefix="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
            dataset="bool_pdarray",
            file_format="Parquet",
        )
        ratens = result_array_tens.to_ndarray()
        ratens.sort()

        rahundreds = result_array_hundreds.to_ndarray()
        rahundreds.sort()

        rafloats = result_array_floats.to_ndarray()
        rafloats.sort()
        self.assertListEqual(self.int_tens_ndarray.tolist(), ratens.tolist())
        self.assertListEqual(self.int_hundreds_ndarray.tolist(), rahundreds.tolist())
        self.assertListEqual(self.float_ndarray.tolist(), rafloats.tolist())
        self.assertEqual(len(self.bool_pdarray), len(result_array_bools))

        # Test load with invalid prefix
        with self.assertRaises(RuntimeError):
            ak.load(
                path_prefix="{}/iotest_dict_column".format(IOTest.io_test_dir),
                dataset="int_tens_pdarray",
            )

        # Test load with invalid file
        with self.assertRaises(RuntimeError):
            ak.load(path_prefix="{}/not-a-file".format(IOTest.io_test_dir), dataset="int_tens_pdarray")

    def testLoadAll(self):
        self._create_file(
            columns=self.dict_columns, prefix_path="{}/iotest_dict_columns".format(IOTest.io_test_dir)
        )

        results = ak.load_all(path_prefix="{}/iotest_dict_columns".format(IOTest.io_test_dir))
        self.assertTrue("bool_pdarray" in results)
        self.assertTrue("float_pdarray" in results)
        self.assertTrue("int_tens_pdarray" in results)
        self.assertTrue("int_hundreds_pdarray" in results)

        # test load_all with file_format parameter usage
        ak.to_parquet(
            columns=self.dict_columns,
            prefix_path="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
        )
        results = ak.load_all(
            file_format="Parquet",
            path_prefix="{}/iotest_dict_columns_parquet".format(IOTest.io_test_dir),
        )
        self.assertTrue("bool_pdarray" in results)
        self.assertTrue("float_pdarray" in results)
        self.assertTrue("int_tens_pdarray" in results)
        self.assertTrue("int_hundreds_pdarray" in results)

        # # Test load_all with invalid prefix
        with self.assertRaises(ValueError):
            ak.load_all(path_prefix="{}/iotest_dict_column".format(IOTest.io_test_dir))

        # Test load with invalid file
        with self.assertRaises(RuntimeError):
            ak.load_all(path_prefix="{}/not-a-file".format(IOTest.io_test_dir))

    def testGetDataSets(self):
        """
        Creates 1..n files depending upon the number of arkouda_server locales containing three
        datasets and confirms the expected number of datasets along with the dataset names

        :return: None
        :raise: AssertionError if the input and returned dataset names don't match
        """
        self._create_file(
            columns=self.dict_columns, prefix_path="{}/iotest_dict_columns".format(IOTest.io_test_dir)
        )
        datasets = ak.get_datasets("{}/iotest_dict_columns_LOCALE0000".format(IOTest.io_test_dir))

        self.assertEqual(4, len(datasets))
        for dataset in datasets:
            self.assertIn(dataset, self.names)

        # Test load_all with invalid filename
        with self.assertRaises(RuntimeError):
            ak.get_datasets("{}/iotest_dict_columns_LOCALE000".format(IOTest.io_test_dir))

    def testSaveStringsDataset(self):
        # Create, save, and load Strings dataset
        strings_array = ak.array(["testing string{}".format(num) for num in list(range(0, 25))])
        strings_array.to_hdf("{}/strings-test".format(IOTest.io_test_dir), dataset="strings")
        r_strings_array = ak.load("{}/strings-test".format(IOTest.io_test_dir), dataset="strings")

        strings = strings_array.to_ndarray()
        strings.sort()
        r_strings = r_strings_array.to_ndarray()
        r_strings.sort()
        self.assertListEqual(strings.tolist(), r_strings.tolist())

        # Read a part of a saved Strings dataset from one hdf5 file
        r_strings_subset = ak.read_hdf(filenames="{}/strings-test_LOCALE0000".format(IOTest.io_test_dir))
        self.assertIsNotNone(r_strings_subset)
        self.assertTrue(isinstance(r_strings_subset[0], str))
        self.assertIsNotNone(
            ak.read_hdf(
                filenames="{}/strings-test_LOCALE0000".format(IOTest.io_test_dir),
                datasets="strings/values",
            )
        )
        self.assertIsNotNone(
            ak.read_hdf(
                filenames="{}/strings-test_LOCALE0000".format(IOTest.io_test_dir),
                datasets="strings/segments",
            )
        )

        # Repeat the test using the calc_string_offsets=True option to
        # have server calculate offsets array
        r_strings_subset = ak.read_hdf(
            filenames=f"{IOTest.io_test_dir}/strings-test_LOCALE0000", calc_string_offsets=True
        )
        self.assertIsNotNone(r_strings_subset)
        self.assertTrue(isinstance(r_strings_subset[0], str))
        self.assertIsNotNone(
            ak.read_hdf(
                filenames=f"{IOTest.io_test_dir}/strings-test_LOCALE0000",
                datasets="strings/values",
                calc_string_offsets=True,
            )
        )
        self.assertIsNotNone(
            ak.read_hdf(
                filenames=f"{IOTest.io_test_dir}/strings-test_LOCALE0000",
                datasets="strings/segments",
                calc_string_offsets=True,
            )
        )

    def testStringsWithoutOffsets(self):
        """
        This tests both saving & reading a strings array without saving and reading the offsets to HDF5.
        Instead the offsets array will be derived from the values/bytes area by looking for null-byte
        terminator strings
        """
        strings_array = ak.array(["testing string{}".format(num) for num in list(range(0, 25))])
        strings_array.to_hdf(
            "{}/strings-test".format(IOTest.io_test_dir), dataset="strings", save_offsets=False
        )
        r_strings_array = ak.load(
            "{}/strings-test".format(IOTest.io_test_dir), dataset="strings", calc_string_offsets=True
        )
        strings = strings_array.to_ndarray()
        strings.sort()
        r_strings = r_strings_array.to_ndarray()
        r_strings.sort()
        self.assertListEqual(strings.tolist(), r_strings.tolist())

    def testSaveLongStringsDataset(self):
        # Create, save, and load Strings dataset
        strings = ak.array(
            [
                "testing a longer string{} to be written, loaded and appended".format(num)
                for num in list(range(0, 26))
            ]
        )
        strings.to_hdf("{}/strings-test".format(IOTest.io_test_dir), dataset="strings")

        n_strings = strings.to_ndarray()
        n_strings.sort()
        r_strings = ak.load("{}/strings-test".format(IOTest.io_test_dir), dataset="strings").to_ndarray()
        r_strings.sort()

        self.assertListEqual(n_strings.tolist(), r_strings.tolist())

    def testSaveMixedStringsDataset(self):
        strings_array = ak.array(["string {}".format(num) for num in list(range(0, 25))])
        m_floats = ak.array([x / 10.0 for x in range(0, 10)])
        m_ints = ak.array(list(range(0, 10)))
        ak.to_hdf(
            {"m_strings": strings_array, "m_floats": m_floats, "m_ints": m_ints},
            "{}/multi-type-test".format(IOTest.io_test_dir),
        )
        r_mixed = ak.load_all("{}/multi-type-test".format(IOTest.io_test_dir))

        self.assertListEqual(
            np.sort(strings_array.to_ndarray()).tolist(),
            np.sort(r_mixed["m_strings"].to_ndarray()).tolist(),
        )
        self.assertIsNotNone(r_mixed["m_floats"])
        self.assertIsNotNone(r_mixed["m_ints"])

        r_floats = ak.sort(ak.load("{}/multi-type-test".format(IOTest.io_test_dir), dataset="m_floats"))
        self.assertListEqual(m_floats.to_list(), r_floats.to_list())

        r_ints = ak.sort(ak.load("{}/multi-type-test".format(IOTest.io_test_dir), dataset="m_ints"))
        self.assertListEqual(m_ints.to_list(), r_ints.to_list())

        strings = strings_array.to_ndarray()
        strings.sort()
        r_strings = ak.load(
            "{}/multi-type-test".format(IOTest.io_test_dir), dataset="m_strings"
        ).to_ndarray()
        r_strings.sort()

        self.assertListEqual(strings.tolist(), r_strings.tolist())

    def testAppendStringsDataset(self):
        strings_array = ak.array(["string {}".format(num) for num in list(range(0, 25))])
        strings_array.to_hdf("{}/append-strings-test".format(IOTest.io_test_dir), dataset="strings")
        strings_array.to_hdf(
            "{}/append-strings-test".format(IOTest.io_test_dir), dataset="strings-dupe", mode="append"
        )

        r_strings = ak.load("{}/append-strings-test".format(IOTest.io_test_dir), dataset="strings")
        r_strings_dupe = ak.load(
            "{}/append-strings-test".format(IOTest.io_test_dir), dataset="strings-dupe"
        )
        self.assertListEqual(r_strings.to_list(), r_strings_dupe.to_list())

    def testAppendMixedStringsDataset(self):
        strings_array = ak.array(["string {}".format(num) for num in list(range(0, 25))])
        strings_array.to_hdf("{}/append-multi-type-test".format(IOTest.io_test_dir), dataset="m_strings")
        m_floats = ak.array([x / 10.0 for x in range(0, 10)])
        m_ints = ak.array(list(range(0, 10)))
        ak.to_hdf(
            {"m_floats": m_floats, "m_ints": m_ints},
            "{}/append-multi-type-test".format(IOTest.io_test_dir),
            mode="append",
        )
        r_mixed = ak.load_all("{}/append-multi-type-test".format(IOTest.io_test_dir))

        self.assertIsNotNone(r_mixed["m_floats"])
        self.assertIsNotNone(r_mixed["m_ints"])

        r_floats = ak.sort(
            ak.load("{}/append-multi-type-test".format(IOTest.io_test_dir), dataset="m_floats")
        )
        r_ints = ak.sort(
            ak.load("{}/append-multi-type-test".format(IOTest.io_test_dir), dataset="m_ints")
        )
        self.assertListEqual(m_floats.to_list(), r_floats.to_list())
        self.assertListEqual(m_ints.to_list(), r_ints.to_list())

        strings = strings_array.to_ndarray()
        strings.sort()
        r_strings = r_mixed["m_strings"].to_ndarray()
        r_strings.sort()

        self.assertListEqual(strings.tolist(), r_strings.tolist())

    def testStrictTypes(self):
        N = 100
        prefix = "{}/strict-type-test".format(IOTest.io_test_dir)
        inttypes = [np.uint32, np.int64, np.uint16, np.int16]
        floattypes = [np.float32, np.float64, np.float32, np.float64]
        for i, (it, ft) in enumerate(zip(inttypes, floattypes)):
            with h5py.File("{}-{}".format(prefix, i), "w") as f:
                idata = np.arange(i * N, (i + 1) * N, dtype=it)
                id = f.create_dataset("integers", data=idata)
                id.attrs["ObjType"] = 1
                fdata = np.arange(i * N, (i + 1) * N, dtype=ft)
                fd = f.create_dataset("floats", data=fdata)
                fd.attrs["ObjType"] = 1
        with self.assertRaises(RuntimeError):
            ak.read_hdf(prefix + "*")

        a = ak.read_hdf(prefix + "*", strict_types=False)
        self.assertListEqual(a["integers"].to_list(), np.arange(len(inttypes) * N).tolist())
        self.assertTrue(
            np.allclose(a["floats"].to_ndarray(), np.arange(len(floattypes) * N, dtype=np.float64))
        )

    def testTo_ndarray(self):
        ones = ak.ones(10)
        n_ones = ones.to_ndarray()
        new_ones = ak.array(n_ones)
        self.assertListEqual(ones.to_list(), new_ones.to_list())

        empty_ones = ak.ones(0)
        n_empty_ones = empty_ones.to_ndarray()
        new_empty_ones = ak.array(n_empty_ones)
        self.assertListEqual(empty_ones.to_list(), new_empty_ones.to_list())

    def testSmallArrayToHDF5(self):
        a1 = ak.array([1])
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            a1.to_hdf(f"{tmp_dirname}/small_numeric", dataset="a1")
            # Now load it back in
            a2 = ak.load(f"{tmp_dirname}/small_numeric", dataset="a1")
            self.assertEqual(str(a1), str(a2))

    # This tests small array corner cases on multi-locale environments
    def testSmallStringArrayToHDF5(self):
        a1 = ak.array(["ab", "cd"])
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            a1.to_hdf(f"{tmp_dirname}/small_string_array", dataset="a1")
            # Now load it back in
            a2 = ak.load(f"{tmp_dirname}/small_string_array", dataset="a1")
            self.assertEqual(str(a1), str(a2))

        # Test a single string
        b1 = ak.array(["123456789"])
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            b1.to_hdf(f"{tmp_dirname}/single_string", dataset="b1")
            # Now load it back in
            b2 = ak.load(f"{tmp_dirname}/single_string", dataset="b1")
            self.assertEqual(str(b1), str(b2))

    def testUint64ToFromHDF5(self):
        """
        Test our ability to read/write uint64 to HDF5
        """
        npa1 = np.array(
            [18446744073709551500, 18446744073709551501, 18446744073709551502], dtype=np.uint64
        )
        pda1 = ak.array(npa1)
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            pda1.to_hdf(f"{tmp_dirname}/small_numeric", dataset="pda1")
            # Now load it back in
            pda2 = ak.load(f"{tmp_dirname}/small_numeric", dataset="pda1")
            self.assertEqual(str(pda1), str(pda2))
            self.assertEqual(18446744073709551500, pda2[0])
            self.assertListEqual(pda2.to_list(), npa1.tolist())

    def testUint64ToFromArray(self):
        """
        Test conversion to and from numpy array / pdarray using unsigned 64bit integer (uint64)
        """
        npa1 = np.array(
            [18446744073709551500, 18446744073709551501, 18446744073709551502], dtype=np.uint64
        )
        pda1 = ak.array(npa1)
        self.assertEqual(18446744073709551500, pda1[0])
        self.assertListEqual(pda1.to_list(), npa1.tolist())

    def testHdfUnsanitizedNames(self):
        # Test when quotes are part of the dataset name
        my_arrays = {'foo"0"': ak.arange(100), 'bar"': ak.arange(100)}
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            ak.to_hdf(my_arrays, f"{tmp_dirname}/bad_dataset_names")
            ak.read_hdf(f"{tmp_dirname}/bad_dataset_names*")

    def testInternalVersions(self):
        """
        Test loading legacy files to ensure they can still be read.
        Test loading internal arkouda hdf5 structuring by loading v0 and v1 files.
        v1 contains _arkouda_metadata group and attributes, v0 does not.
        Files are located under `test/resources` ... where server-side unit tests are located.
        """
        # Note: pytest unit tests are located under "tests/" vs chapel "test/"
        # The test files are located in the Chapel `test/resources` directory
        # Determine where the test was launched by inspecting our path and update it accordingly
        cwd = os.getcwd()
        if cwd.endswith("tests"):  # IDEs may launch unit tests from this location
            cwd = cwd + "/server/resources"
        else:  # assume arkouda root dir
            cwd += "/tests/server/resources"

        # Now that we've figured out our loading path, load the files and test the lengths
        v0 = ak.load(cwd + "/array_v0.hdf5", file_format="hdf5")
        v1 = ak.load(cwd + "/array_v1.hdf5", file_format="hdf5")
        self.assertEqual(50, v0.size)
        self.assertEqual(50, v1.size)

    def test_multi_dim_rdwr(self):
        arr = ak.ArrayView(ak.arange(27), ak.array([3, 3, 3]))
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            arr.to_hdf(tmp_dirname + "/multi_dim_test", dset="MultiDimObj", mode="append")
            # load data back
            read_arr = ak.read_hdf(tmp_dirname + "/multi_dim_test*", datasets="MultiDimObj")
            self.assertTrue(np.array_equal(arr.to_ndarray(), read_arr.to_ndarray()))

    def test_legacy_read(self):
        cwd = os.getcwd()
        if cwd.endswith("tests"):  # IDEs may launch unit tests from this location
            cwd = cwd + "/../resources/hdf5-testing"
        else:  # assume arkouda root dir
            cwd += "/resources/hdf5-testing"
        rd_arr = ak.read_hdf(f"{cwd}/Legacy_String.hdf5")

        self.assertListEqual(["ABC", "DEF", "GHI"], rd_arr.to_list())

    def test_csv_read_write(self):
        # first test that can read csv with no header not written by Arkouda
        cols = ["ColA", "ColB", "ColC"]
        a = ["ABC", "DEF"]
        b = ["123", "345"]
        c = ["3.14", "5.56"]
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            with open(f"{tmp_dirname}/non_ak.csv", "w") as f:
                f.write(",".join(cols) + "\n")
                f.write(f"{a[0]},{b[0]},{c[0]}\n")
                f.write(f"{a[1]},{b[1]},{c[1]}\n")

            data = ak.read_csv(f"{tmp_dirname}/non_ak.csv")
            self.assertListEqual(list(data.keys()), cols)
            self.assertListEqual(data["ColA"].to_list(), a)
            self.assertListEqual(data["ColB"].to_list(), b)
            self.assertListEqual(data["ColC"].to_list(), c)

            data = ak.read_csv(f"{tmp_dirname}/non_ak.csv", datasets="ColB")
            self.assertIsInstance(data, ak.Strings)
            self.assertListEqual(data.to_list(), b)

        # test can read csv with header not written by Arkouda
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            with open(f"{tmp_dirname}/non_ak.csv", "w") as f:
                f.write("**HEADER**\n")
                f.write("str,int64,float64\n")
                f.write("*/HEADER/*\n")
                f.write(",".join(cols) + "\n")
                f.write(f"{a[0]},{b[0]},{c[0]}\n")
                f.write(f"{a[1]},{b[1]},{c[1]}\n")

            data = ak.read_csv(f"{tmp_dirname}/non_ak.csv")
            self.assertListEqual(list(data.keys()), cols)
            self.assertListEqual(data["ColA"].to_list(), a)
            self.assertListEqual(data["ColB"].to_list(), [int(x) for x in b])
            self.assertListEqual(data["ColC"].to_list(), [round(float(x), 2) for x in c])

            # test reading subset of columns
            data = ak.read_csv(f"{tmp_dirname}/non_ak.csv", datasets="ColB")
            self.assertIsInstance(data, ak.pdarray)
            self.assertListEqual(data.to_list(), [int(x) for x in b])

        # test writing file with Arkouda with non-standard delim
        d = {
            cols[0]: ak.array(a),
            cols[1]: ak.array([int(x) for x in b]),
            cols[2]: ak.array([round(float(x), 2) for x in c]),
        }
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            ak.to_csv(d, f"{tmp_dirname}/non_standard_delim.csv", col_delim="|*|")

            # test reading that file with Arkouda
            data = ak.read_csv(f"{tmp_dirname}/non_standard_delim*", column_delim="|*|")
            self.assertListEqual(list(data.keys()), cols)
            self.assertListEqual(data["ColA"].to_list(), a)
            self.assertListEqual(data["ColB"].to_list(), [int(x) for x in b])
            self.assertListEqual(data["ColC"].to_list(), [round(float(x), 2) for x in c])

            # test reading subset of columns
            data = ak.read_csv(
                f"{tmp_dirname}/non_standard_delim*", datasets="ColB", column_delim="|*|"
            )
            self.assertIsInstance(data, ak.pdarray)
            self.assertListEqual(data.to_list(), [int(x) for x in b])

        # larger data set testing
        with tempfile.TemporaryDirectory(dir=IOTest.io_test_dir) as tmp_dirname:
            d = {
                "ColA": ak.randint(0, 50, 101),
                "ColB": ak.randint(0, 50, 101),
                "ColC": ak.randint(0, 50, 101)
            }

            ak.to_csv(d, f"{tmp_dirname}/non_equal_set.csv")
            data = ak.read_csv(f"{tmp_dirname}/non_equal_set*")
            self.assertListEqual(data["ColA"].to_list(), d["ColA"].to_list())
            self.assertListEqual(data["ColB"].to_list(), d["ColB"].to_list())
            self.assertListEqual(data["ColC"].to_list(), d["ColC"].to_list())


    def tearDown(self):
        super(IOTest, self).tearDown()
        for f in glob.glob("{}/*".format(IOTest.io_test_dir)):
            os.remove(f)

    @classmethod
    def tearDownClass(cls):
        super(IOTest, cls).tearDownClass()
        shutil.rmtree(IOTest.io_test_dir)
