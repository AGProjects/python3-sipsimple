
"""Parses and produces Filetransfer payloads according to RCC.07 """


__all__ = ['namespace',
           'namespace_ext',
           'FTHTTPDocument',
           'FileSize',
           'FileName',
           'ContentType',
           'Data',
           'BrandedUrl',
           'FileHash',
           'FileInfo']


from sipsimple.payloads import XMLDocument, XMLListRootElement, XMLAnyURIElement, XMLStringElement, XMLElementChild, XMLEmptyElement, XMLElement, XMLNonNegativeIntegerElement, XMLAttribute
from sipsimple.payloads.datatypes import DateTime, AnyURI


namespace = 'urn:gsma:params:xml:ns:rcs:rcs:fthttp'
namespace_ext = 'urn:gsma:params:xml:ns:rcs:rcs:up:fthttpext'


class FTHTTPDocument(XMLDocument):
    content_type = "application/vnd.gsma.rcs-ft-http+xml"


FTHTTPDocument.register_namespace(namespace, prefix=None, schema='rcs-fthttp.xsd')
FTHTTPDocument.register_namespace(namespace_ext, prefix='x', schema='rcs-fthttd-ext.xsd')


# Attribute value types


class FileInfoTypeValue(str):
    def __new__(cls, value):
        if value not in ['file', 'thumbnail']:
            raise ValueError("illegal value file info type")
        return value

# Elements


class FileSize(XMLNonNegativeIntegerElement):
    _xml_tag = 'file-size'
    _xml_namespace = namespace
    _xml_document = FTHTTPDocument


class FileName(XMLStringElement):
    _xml_tag = 'file-name'
    _xml_namespace = namespace
    _xml_document = FTHTTPDocument


class ContentType(XMLStringElement):
    _xml_tag = 'content-type'
    _xml_namespace = namespace
    _xml_document = FTHTTPDocument


class Data(XMLEmptyElement):
    _xml_tag = 'data'
    _xml_namespace = namespace
    _xml_document = FTHTTPDocument

    url = XMLAttribute('url', type=AnyURI, required=True, test_equal=True)
    until = XMLAttribute('until', type=DateTime, required=False, test_equal=True)

    def __init__(self, url=None, until=None):
        XMLEmptyElement.__init__(self)
        self.url = url
        self.until = until


class BrandedUrl(XMLAnyURIElement):
    _xml_tag = 'branded-url'
    _xml_namespace = namespace_ext
    _xml_document = FTHTTPDocument


class FileHash(XMLStringElement):
    _xml_tag = 'file-hash'
    _xml_namespace = namespace_ext
    _xml_document = FTHTTPDocument


class FileInfo(XMLElement):
    _xml_tag = 'file-info'
    _xml_namespace = namespace
    _xml_document = FTHTTPDocument

    type = XMLAttribute('type', type=FileInfoTypeValue, required=True, test_equal=True)
    file_disposition = XMLAttribute('file_disposition', type='str', required=False, test_equal=True)

    file_size = XMLElementChild('file_size', type=FileSize, required=True, test_equal=True)
    file_name = XMLElementChild('file_name', type=FileName, required=False, test_equal=True)
    content_type = XMLElementChild('content_type', type=ContentType, required=True, test_equal=True)
    data = XMLElementChild('data', type=Data, required=True, test_equal=True)
    branded_url = XMLElementChild('branded_url', type=BrandedUrl, required=False, test_equal=True)
    hash = XMLElementChild('hash', type=FileHash, required=False, test_equal=True)

    def __init__(self, type='file', file_disposition=None, file_name=None, file_size=None, content_type=None, data=None, branded_url=None, url=None, until=None, hash=None):
        XMLElement.__init__(self)
        self.type = type
        self.file_disposition = file_disposition
        self.file_size = file_size
        if type == 'file' and not file_name:
            raise ValueError("File name is required for type file")
        self.file_name = file_name
        self.content_type = content_type
        self.data = data
        if url:
            self.data = Data(url=url, until=until)
        self.branded_url = branded_url
        self.hash = hash

# document


class FTHTTPMessage(XMLListRootElement):
    _xml_tag = 'file'
    _xml_namespace = namespace
    _xml_document = FTHTTPDocument
    _xml_item_type = FileInfo

    def __init__(self, file=[]):
        XMLListRootElement.__init__(self)
        self.update(file)
